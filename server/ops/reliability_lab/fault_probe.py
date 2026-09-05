"""Two real relay processes, PostgreSQL, Redis, and loopback WebSocket clients.

Only an isolated local PostgreSQL database and the dedicated lab Redis port are
allowed. Redis restart control targets the named lab WSL distro, never a service.
"""
import argparse
import asyncio
import hashlib
import json
import os
import secrets
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlparse, urlunparse

import psycopg
from psycopg import sql
import redis.asyncio as redis
import websockets

from server.ops.reliability_lab.queue_probe import validate_url


async def eventually(predicate, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if await predicate():
            return
        await asyncio.sleep(.1)
    raise AssertionError("Condition not satisfied before deadline")


class Worker:
    def __init__(self, name, env, directory):
        self.env = {**env, "MESH_WORKER_ID": name, "MESH_LAB_PORT": "0"}
        self.ready = directory / (name + ".ready.json")
        self.env["MESH_LAB_READY"] = str(self.ready)
        self.log = open(directory / (name + ".log"), "ab", buffering=0)
        self.process = None

    async def start(self):
        self.ready.unlink(missing_ok=True)
        self.process = subprocess.Popen([sys.executable, "-u", "-m", "server.ops.reliability_lab.worker"],
            env=self.env, stdout=self.log, stderr=subprocess.STDOUT,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        async def ready():
            if self.process.poll() is not None:
                raise RuntimeError(f"Worker {self.env['MESH_WORKER_ID']} failed; see its lab log")
            return self.ready.exists()
        await eventually(ready, 60)
        self.port = json.loads(self.ready.read_text())["port"]
        self.env["MESH_LAB_PORT"] = str(self.port)

    def kill(self):
        if self.process is not None and self.process.poll() is None:
            self.process.kill()
            self.process.wait(timeout=10)

    def close(self):
        self.kill()
        self.log.close()


class Client:
    def __init__(self, worker, login, node, token, delay=0, delta=False):
        self.worker, self.login, self.node, self.token = worker, login, node, token
        self.delay = delay
        self.delta = delta
        self.delta_checkpoints = 0
        self.arrivals = {}
        self.cursor = 0
        self.messages = {}
        self.acks = set()
        self.checkpoints = 0
        self.errors = []
        self.signals = []
        self.task = None
        self.socket = None

    async def connect(self):
        self.socket = await websockets.connect(f"ws://127.0.0.1:{self.worker.port}",
            max_size=128 * 1024 * 1024, max_queue=1, open_timeout=15)
        await self.socket.send(json.dumps({
            "type": "server_hello", "node_id": self.node, "login": self.login,
            "password": self.token, "username": self.login, "display_name": self.login,
            "public_username": self.login, "server_token": self.token,
            "encryption_public_key": "public-key:" + self.node,
            "protocol_version": 5, "min_protocol_version": 5,
            "app_version": "lab-test", "supports_sync_v2": True,
            "supports_sync_v2_delta": self.delta, "supports_reliable_sync_v2": True,
            "supports_sync_v2_delta_batch": self.delta,
            "supports_mutation_ack": True, "supports_account_live_fanout": True,
            "sync_cursor": self.cursor,
        }))
        self.inflight = True
        self.task = asyncio.create_task(self.receive())

    async def send(self, packet):
        await self.socket.send(json.dumps({"source_node": self.node, "protocol_version": 5, **packet}))

    async def receive(self):
        snapshot = None
        delta_begin = None
        events = []
        try:
            async for raw in self.socket:
                if self.delay:
                    await asyncio.sleep(self.delay)
                packet = json.loads(raw)
                kind = packet.get("type")
                if kind == "server_error":
                    raise RuntimeError(str(packet.get("message") or packet.get("code")))
                if str(kind).startswith("call_"):
                    self.signals.append(packet)
                    self.signals = self.signals[-200:]
                if kind == "mutation_ack":
                    if not packet.get("ok"):
                        raise RuntimeError("Mutation rejected: " + str(packet.get("reason")))
                    self.acks.add(packet["outbox_id"])
                elif kind == "server_sync":
                    delta_begin = None
                    snapshot = {str(row.get("id") or row.get("message_id")): row["message"]
                                for row in packet["direct_messages"] + packet.get("group_messages", [])}
                elif kind == "server_sync_delta_begin":
                    if int(packet["source_cursor"]) != self.cursor:
                        raise RuntimeError("Delta does not start at local checkpoint")
                    delta_begin, events = packet, []
                    snapshot = dict(self.messages)
                elif kind in {"server_sync_delta_event", "server_sync_delta_batch"}:
                    if not delta_begin or packet["sync_id"] != delta_begin["sync_id"]:
                        raise RuntimeError("Delta outside matching transaction")
                    events.extend(packet.get("events", [packet.get("event")]))
                elif kind == "server_sync_done":
                    if snapshot is None:
                        raise RuntimeError("Done before snapshot")
                    if delta_begin:
                        canonical = json.dumps(events, ensure_ascii=False,
                            sort_keys=True, separators=(",", ":")).encode("utf-8")
                        digest = hashlib.sha256(canonical).hexdigest()
                        if (len(events) != delta_begin["event_count"]
                                or digest != delta_begin["event_digest_sha256"]
                                or packet["sync_cursor"] != delta_begin["target_cursor"]
                                or packet["sync_v2"]["sync_id"] != delta_begin["sync_id"]):
                            raise RuntimeError("Delta checkpoint failed validation")
                        cursor = self.cursor
                        for event in events:
                            if not cursor < event["cursor"] <= packet["sync_cursor"]:
                                raise RuntimeError("Delta events out of order")
                            cursor = event["cursor"]
                            payload = event["payload"]
                            identity = (payload.get("group_message_id") or payload.get("message_id")
                                        or payload.get("packet_id"))
                            if event["packet_type"] in {"chat_message", "message_edit", "group_message", "group_message_edit"}:
                                snapshot[identity] = payload["message"]
                            elif event["packet_type"] in {"message_delete", "group_message_delete"}:
                                snapshot.pop(identity, None)
                        self.delta_checkpoints += 1
                        delta_begin = None
                    for identity, value in snapshot.items():
                        if self.messages.get(identity) != value:
                            self.arrivals[identity] = time.perf_counter()
                    self.messages = snapshot
                    snapshot = None
                    self.cursor = int(packet["sync_cursor"])
                    self.checkpoints += 1
                    self.inflight = False
                    await self.send({"type": "sync_v2_ack", "cursor": self.cursor})
                elif kind == "reliable_sync_hint":
                    if self.cursor >= packet["cursor"]:
                        await self.send({"type": "sync_v2_ack", "cursor": self.cursor})
                    elif not self.inflight:
                        self.inflight = True
                        await self.send({"type": "reliable_sync_request", "cursor": self.cursor})
                elif kind in {"chat_message", "message_edit", "message_delete", "group_message", "group_message_edit", "group_message_delete"}:
                    raise RuntimeError("Negotiated receiver got a legacy live payload")
        except websockets.ConnectionClosed:
            pass
        except Exception as error:
            self.errors.append(str(error))

    async def wait_message(self, message_id, value, timeout=45):
        async def ready():
            if self.errors:
                raise AssertionError(self.errors)
            return self.messages.get(message_id) == value
        await eventually(ready, timeout)

    async def close(self):
        if self.socket:
            await self.socket.close()
        if self.task:
            self.task.cancel()
            await asyncio.gather(self.task, return_exceptions=True)


async def run(args):
    base = os.environ["MESH_TEST_DATABASE_URL"]
    validate_url(base)
    suffix = secrets.token_hex(5)
    db_name = "meshchat_reliability_test_fault_" + suffix
    parsed = urlparse(base)
    admin_url = urlunparse(parsed._replace(path="/postgres"))
    db_url = urlunparse(parsed._replace(path="/" + db_name))
    directory = Path(args.output).resolve() / suffix
    directory.mkdir(parents=True)
    prefix = "meshchat-lab-" + suffix
    token = secrets.token_urlsafe(24)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("MESH_", "GROQ_", "OPENAI_"))}
    env.update(MESH_DATABASE_BACKEND="postgres", MESH_DATABASE_URL=db_url,
        MESH_REDIS_URL="redis://127.0.0.1:16379/0", MESH_REDIS_PREFIX=prefix,
        MESH_RELIABLE_DELIVERY_ENABLED="1", MESH_SERVER_TOKEN=token,
        MESH_SYNC_V2_DELTA_TEST_ACCOUNTS="labalice,labbob" if args.delta else "",
        MESH_EMAIL_2FA_LEGACY_CLIENTS_ALLOWED="1", MESH_CALL_SIGNALING_ENABLED="0",
        MESH_REALTIME_HEARTBEAT_SECONDS="5", MESH_REALTIME_PRESENCE_TTL_SECONDS="15",
        MESH_SERVER_DB=str(directory / "unused.db"))
    r = redis.Redis(host="127.0.0.1", port=16379, decode_responses=True,
                    socket_connect_timeout=5, socket_timeout=5)
    workers, clients, results = [], [], {}
    admin = psycopg.connect(admin_url, autocommit=True)
    admin.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(db_name)))
    try:
        results["redis_version"] = (await r.info("server"))["redis_version"]
        for name in ("worker-a", "worker-b"):
            worker = Worker(name, env, directory)
            workers.append(worker)
            await worker.start()
        alice = Client(workers[0], "labalice", "alice-phone", token, delta=args.delta)
        bob = Client(workers[1], "labbob", "bob-phone", token, delta=args.delta)
        clients.extend([alice, bob])
        for client in clients:
            await client.connect()
        async def connected():
            for client in clients:
                if client.errors:
                    raise AssertionError(client.errors)
            return all(client.checkpoints for client in clients)
        await eventually(connected)
        account_key = f"{prefix}:account:client:{bob.login}:nodes"
        await r.pexpire(account_key, 1)
        await asyncio.sleep(.02)
        async def membership_restored():
            return bob.node in await r.smembers(account_key)
        await eventually(membership_restored, 20)
        results["expired_account_membership_restored"] = True

        async def message(identity, value="synthetic"):
            await alice.send({"type": "chat_message", "packet_id": identity,
                "operation_id": "send:" + identity, "outbox_id": identity,
                "destination_node": bob.node, "message": value})

        start = time.perf_counter()
        await message("baseline")
        await bob.wait_message("baseline", "synthetic")
        results["baseline_delivery_ms"] = round((bob.arrivals["baseline"] - start) * 1000, 1)
        print("PASS baseline cross-worker delivery", flush=True)

        # Test edits and deletes while the receiver application consumes slowly.
        bob.delay = .075
        start = time.perf_counter()
        for index in range(args.messages):
            await message(f"load-{index}", "x" * 1024)
        await bob.wait_message(f"load-{args.messages - 1}", "x" * 1024, 90)
        for index in range(args.messages):
            if bob.messages.get(f"load-{index}") != "x" * 1024:
                raise AssertionError("Missing message in load snapshot")
        results["slow_consumer_messages"] = args.messages
        results["slow_consumer_seconds"] = round(time.perf_counter() - start, 2)
        bob.delay = 0
        await alice.send({"type": "message_edit", "message_id": "baseline", "message": "edited",
            "destination_node": bob.node, "operation_id": "edit:baseline", "outbox_id": "edit"})
        await bob.wait_message("baseline", "edited")
        await alice.send({"type": "message_delete", "message_id": "baseline",
            "destination_node": bob.node, "operation_id": "delete:baseline", "outbox_id": "delete"})
        await bob.wait_message("baseline", None)
        print("PASS slow consumer, edit, delete", flush=True)

        before = bob.checkpoints
        workers[1].kill()
        await bob.close()
        await message("during-worker-stop")
        await workers[1].start()
        await bob.connect()
        await bob.wait_message("during-worker-stop", "synthetic")
        if "baseline" in bob.messages or bob.checkpoints <= before:
            raise AssertionError("Restart restored stale state")
        print("PASS killed worker and reconnect", flush=True)
        results["worker_restart"] = "passed"

        if args.restart_redis:
            # Only the dedicated local lab daemon on port 16379 is affected.
            config = await r.config_get("pidfile")
            if config.get("pidfile") != "/tmp/meshchat-lab-redis.pid":
                raise RuntimeError("Refusing to stop a non-lab Redis daemon")
            try:
                await asyncio.wait_for(r.shutdown(nosave=True), 10)
            except asyncio.TimeoutError:
                pass  # A shutdown response can be lost with the connection.
            await message("during-redis-stop")
            await asyncio.sleep(2)
            process = await asyncio.create_subprocess_exec("wsl", "-d", "MeshChat-Reliability-Lab",
                "--", "redis-server", "/mnt/e/meshchat-reliability-lab/redis.conf",
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            try:
                await asyncio.wait_for(process.communicate(), 30)
            except asyncio.TimeoutError:
                process.kill()
                await process.communicate()
                raise
            if process.returncode:
                raise RuntimeError("Could not restart dedicated lab Redis")
            await bob.wait_message("during-redis-stop", "synthetic", 55)
            results["redis_restart_without_client_reconnect"] = "passed"
            print("PASS Redis restart without reconnecting clients", flush=True)
            for client in clients:
                presence = await r.hgetall(f"{prefix}:presence:client:{client.node}")
                members = await r.smembers(f"{prefix}:account:client:{client.login}:nodes")
                if presence.get("login") != client.login or client.node not in members:
                    raise AssertionError("Redis presence/account membership not restored")
        results["receiver_delta_checkpoints"] = bob.delta_checkpoints
        if args.delta and not bob.delta_checkpoints:
            raise AssertionError("Delta mode requested but never exercised")
        expected_acks = {"baseline", "edit", "delete", "during-worker-stop"}
        expected_acks.update(f"load-{index}" for index in range(args.messages))
        if args.restart_redis:
            expected_acks.add("during-redis-stop")
        async def acknowledged():
            return expected_acks <= alice.acks
        await eventually(acknowledged)
        results["sender_mutations_acknowledged"] = len(expected_acks)
        if any(client.errors for client in clients):
            raise AssertionError([client.errors for client in clients])
        results["status"] = "passed"
    except Exception as error:
        results.update(status="failed", error=str(error))
        raise
    finally:
        await asyncio.gather(*(client.close() for client in clients), return_exceptions=True)
        for worker in workers:
            worker.close()
        try:
            async for key in r.scan_iter(match=prefix + ":*", count=100):
                await r.delete(key)
        except Exception:
            pass
        await r.aclose()
        admin.execute(sql.SQL("DROP DATABASE {} WITH (FORCE)").format(sql.Identifier(db_name)))
        admin.close()
        (directory / "result.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
        print(json.dumps({"report": str(directory / "result.json"), **results}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    parser.add_argument("--messages", type=int, default=100)
    parser.add_argument("--restart-redis", action="store_true")
    parser.add_argument("--delta", action="store_true")
    args = parser.parse_args()
    if not 1 <= args.messages <= 1000:
        parser.error("messages must be between 1 and 1000")
    asyncio.run(run(args))


if __name__ == "__main__":
    main()
