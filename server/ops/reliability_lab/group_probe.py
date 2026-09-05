"""Bounded synthetic group fan-out with slow and paused loopback receivers."""
import argparse
import asyncio
import json
import os
from pathlib import Path
import secrets
import time
from uuid import uuid4
from urllib.parse import urlparse, urlunparse

import psycopg
from psycopg import sql
import redis.asyncio as redis

from server.ops.reliability_lab.fault_probe import Client, Worker, eventually
from server.ops.reliability_lab.queue_probe import validate_url


async def run(args):
    base = os.environ["MESH_TEST_DATABASE_URL"]
    validate_url(base)
    suffix = secrets.token_hex(5)
    name = "meshchat_reliability_test_group_" + suffix
    parsed = urlparse(base)
    directory = Path(args.output).resolve() / suffix
    directory.mkdir(parents=True)
    prefix = "meshchat-lab-" + suffix
    token = secrets.token_urlsafe(24)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("MESH_", "GROQ_", "OPENAI_"))}
    env.update(MESH_DATABASE_BACKEND="postgres",
        MESH_DATABASE_URL=urlunparse(parsed._replace(path="/" + name)),
        MESH_REDIS_URL="redis://127.0.0.1:16379/0", MESH_REDIS_PREFIX=prefix,
        MESH_RELIABLE_DELIVERY_ENABLED="1", MESH_SYNC_V2_DELTA_ENABLED="1",
        MESH_SERVER_TOKEN=token, MESH_EMAIL_2FA_LEGACY_CLIENTS_ALLOWED="1",
        MESH_CALL_SIGNALING_ENABLED="0", MESH_LAB_SNDBUF="16384",
        MESH_SERVER_DB=str(directory / "unused.db"))
    admin = psycopg.connect(urlunparse(parsed._replace(path="/postgres")), autocommit=True)
    admin.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(name)))
    broker = redis.Redis(host="127.0.0.1", port=16379, decode_responses=True,
                         socket_timeout=5, socket_connect_timeout=5)
    workers, clients, paused = [], [], []
    result = {"participants": args.participants, "messages": args.messages}
    try:
        for index in range(2):
            worker = Worker("group-worker-" + str(index), env, directory)
            workers.append(worker)
            await worker.start()
        # Sequential registration avoids measuring password hashing as delivery load.
        for index in range(args.participants):
            client = Client(workers[index % 2], f"labuser{index}", str(uuid4()), token, delta=True)
            clients.append(client)
            await client.connect()
            async def ready():
                if client.errors:
                    raise AssertionError(client.errors)
                return client.checkpoints > 0
            await eventually(ready)
        owner = clients[0]
        members = [client.node for client in clients]
        async def mutate(kind, identity, **extra):
            await owner.send({"type": kind, "packet_id": identity,
                "operation_id": identity, "outbox_id": identity,
                "destination_node": clients[1].node, "group_id": "lab-group",
                "group_name": "Synthetic group", "owner_node": owner.node,
                "sender": owner.login,
                "members": members, "admins": [], "ttl": 5, **extra})
            async def ack():
                if owner.errors:
                    raise AssertionError(owner.errors)
                return identity in owner.acks
            await eventually(ack, 30)
        await mutate("group_update", "group-create", is_channel=False)
        with psycopg.connect(env["MESH_DATABASE_URL"]) as inspection:
            result["stored_group_members"] = inspection.execute(
                "SELECT COUNT(*) FROM server_group_members WHERE group_id='lab-group'").fetchone()[0]
        print("PASS group created", flush=True)
        slow = clients[1:1 + args.slow]
        for client in slow:
            client.delay = .075
        paused = clients[1 + args.slow:1 + args.slow + args.paused]
        for client in paused:
            client.socket.transport.pause_reading()
        fast = clients[1 + args.slow + args.paused:]
        payload = secrets.token_hex(4096)
        started = time.perf_counter()
        for index in range(args.messages):
            await mutate("group_message", f"message-{index}",
                         group_message_id=f"message-{index}", message=payload)
        async def fast_ready():
            if any(client.errors for client in clients):
                raise AssertionError([client.errors for client in clients if client.errors])
            return all(client.messages.get(f"message-{args.messages - 1}") == payload for client in fast)
        await eventually(fast_ready, 60)
        result["fast_receivers_seconds"] = round(time.perf_counter() - started, 2)
        print("PASS fast receivers delivered while others paused", flush=True)
        await mutate("group_message_edit", "edit", group_message_id="message-0", message="edited")
        await mutate("group_message_delete", "delete", group_message_id="message-1")
        for client in paused:
            client.socket.transport.resume_reading()
        for client in slow:
            client.delay = 0
        async def converged():
            if any(client.errors for client in clients):
                raise AssertionError([client.errors for client in clients if client.errors])
            for client in clients:
                if client.socket.state.name == "CLOSED":
                    await client.close()
                    await client.connect()
                    result["automatic_test_client_reconnects"] = result.get("automatic_test_client_reconnects", 0) + 1
            expected = {f"message-{index}": payload for index in range(args.messages)}
            expected["message-0"] = "edited"
            expected.pop("message-1")
            return all(client.messages == expected for client in clients)
        await eventually(converged, 90)
        result["all_receivers_seconds"] = round(time.perf_counter() - started, 2)
        reconnect = clients[-1]
        await reconnect.close()
        before = reconnect.checkpoints
        await reconnect.connect()
        async def resynced():
            return reconnect.checkpoints > before
        await eventually(resynced)
        await eventually(converged)
        # Signaling only: no microphone, STT provider or real media engine here.
        async def signal(source, target, kind, **extra):
            packet_id = str(uuid4())
            await source.send({"type": kind, "packet_id": packet_id,
                "call_id": "lab-call", "group_id": "lab-group",
                "destination_node": target.node, **extra})
            async def delivered():
                return any(packet.get("packet_id") == packet_id and
                           packet.get("source_node") == source.node for packet in target.signals)
            await eventually(delivered, 20)
            return next(packet for packet in target.signals if packet.get("packet_id") == packet_id)
        guests = clients[-3:]
        call_members = [owner.node, *(guest.node for guest in guests)]
        for guest in guests:
            await signal(owner, guest, "call_offer", sdp="v=0\r\n", group_members=call_members, group_mesh=1)
            await signal(guest, owner, "call_answer", accepted=True, sdp="v=0\r\n", group_mesh=1)
        for index, guest in enumerate(guests):
            for peer in guests[index + 1:]:
                await signal(guest, peer, "call_group_ready", group_mesh=1)
                await signal(peer, guest, "call_group_ready", group_mesh=1)
                offerer, answerer = sorted([guest, peer], key=lambda client: client.node)
                await signal(offerer, answerer, "call_group_offer", group_mesh=1, sdp="v=0\r\n")
                await signal(answerer, offerer, "call_answer", group_mesh=1, accepted=True, sdp="v=0\r\n")
        # A local synthetic entitlement, never a production account or paid AI call.
        with psycopg.connect(env["MESH_DATABASE_URL"]) as setup:
            setup.execute("INSERT INTO account_subscriptions(login,product,plan_code,status,current_period_end) VALUES(%s,'meshpro','monthly','active',CURRENT_TIMESTAMP + INTERVAL '1 day') ON CONFLICT(login,product) DO UPDATE SET status='active',current_period_end=EXCLUDED.current_period_end", (owner.login,))
        async def caption_control(client, action, session_id=""):
            request = str(uuid4())
            await client.send({"type": "call_caption_session_request", "request_id": request,
                              "call_id": "lab-call", "group_id": "lab-group", "action": action,
                              "members": call_members, "session_id": session_id})
            async def responded():
                return any(packet.get("request_id") == request for packet in client.signals)
            await eventually(responded, 20)
            response = next(packet for packet in client.signals if packet.get("request_id") == request)
            if not response.get("ok"):
                raise AssertionError(response)
        await caption_control(owner, "start")
        async def invited():
            return all(any(packet.get("type") == "call_caption_session" and packet.get("enabled") for packet in client.signals) for client in [owner, *guests])
        await eventually(invited, 20)
        session_id = next(packet["session_id"] for packet in owner.signals if packet.get("type") == "call_caption_session")
        for guest in guests:
            await caption_control(guest, "join", session_id)
        with psycopg.connect(env["MESH_DATABASE_URL"]) as inspection:
            approved = inspection.execute("SELECT COUNT(*) FROM call_caption_members WHERE call_id='lab-call' AND consent=1").fetchone()[0]
            if approved != 4:
                raise AssertionError("Caption consent missing across workers")
        for target in [owner, *guests[1:]]:
            received = await signal(guests[0], target, "call_caption", caption_id="lab-phrase",
                text="Synthetic phrase", translation="Translated phrase",
                translation_language="en", final=True, revision=2, caption_session_id=session_id)
            if received.get("translation") != "Translated phrase" or received.get("revision") != 2:
                raise AssertionError("Caption translation/revision changed in transit")
        await caption_control(owner, "stop", session_id)
        with psycopg.connect(env["MESH_DATABASE_URL"]) as inspection:
            if inspection.execute("SELECT COUNT(*) FROM call_caption_sessions WHERE call_id='lab-call'").fetchone()[0]:
                raise AssertionError("Caption sponsorship survived stop")
        result["group_mesh_and_shared_caption_consent"] = "passed"
        await signal(guests[0], owner, "call_end", operation_id="leave-lab-call")
        await signal(owner, guests[1], "call_restart_offer", sdp="v=0\r\n")
        await signal(guests[1], owner, "call_restart_answer", sdp="v=0\r\n")
        result["four_party_call_signaling_and_caption_translation"] = "passed"
        await asyncio.sleep(.3)
        result["worker_metrics"] = [json.loads(worker.ready.with_suffix(".metrics.json").read_text())
                                    for worker in workers]
        result.update(status="passed", slow_receivers=len(slow), paused_receivers=len(paused),
                      receiver_message_checks=args.participants * (args.messages - 1))
    except Exception as error:
        result.update(status="failed", error=str(error))
        raise
    finally:
        for client in paused:
            if client.socket:
                client.socket.transport.resume_reading()
        await asyncio.gather(*(client.close() for client in clients), return_exceptions=True)
        for worker in workers:
            worker.close()
        try:
            async for key in broker.scan_iter(match=prefix + ":*"):
                await broker.delete(key)
        finally:
            await broker.aclose()
            admin.execute(sql.SQL("DROP DATABASE {} WITH (FORCE)").format(sql.Identifier(name)))
            admin.close()
            (directory / "result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
            print(json.dumps({"report": str(directory / "result.json"), **result}), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    parser.add_argument("--participants", type=int, default=24)
    parser.add_argument("--messages", type=int, default=80)
    parser.add_argument("--slow", type=int, default=6)
    parser.add_argument("--paused", type=int, default=4)
    args = parser.parse_args()
    if not (4 <= args.participants <= 100 and 2 <= args.messages <= 300
            and args.slow >= 0 and args.paused >= 0
            and args.slow + args.paused < args.participants - 1):
        parser.error("Require 4..100 participants, 2..300 messages and at least one fast receiver")
    asyncio.run(run(args))
