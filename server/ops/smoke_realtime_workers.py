"""Live smoke test for Redis fanout between balanced relay workers."""

import argparse
import asyncio
import json
import secrets
import sys
from pathlib import Path

import redis.asyncio as redis_async
import websockets


ROOT_DIR = Path(__file__).resolve().parents[2]
if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))

from server.config import REDIS_PREFIX, REDIS_URL, SERVER_TOKEN
from server.server import MeshRelayServer
from server.server_protocol import (
    MIN_SUPPORTED_PROTOCOL_VERSION,
    PROTOCOL_VERSION,
)


async def _connect(uri, login, password, node_id):
    websocket = await websockets.connect(
        uri,
        open_timeout=5,
        close_timeout=2,
    )
    await websocket.send(
        json.dumps(
            {
                "type": "server_hello",
                "protocol_version": PROTOCOL_VERSION,
                "min_protocol_version": MIN_SUPPORTED_PROTOCOL_VERSION,
                "server_token": SERVER_TOKEN,
                "node_id": node_id,
                "username": login,
                "display_name": "Realtime smoke",
                "login": login,
                "password": password,
                "register_if_missing": False,
                "supports_sync_v2": True,
                "supports_sync_v2_delta": True,
                "supports_account_live_fanout": True,
                "supports_mutation_ack": True,
            }
        )
    )
    while True:
        packet = json.loads(await asyncio.wait_for(websocket.recv(), 8))
        if packet.get("type") == "server_error":
            raise RuntimeError(packet)
        if packet.get("type") == "server_welcome":
            return websocket


async def _wait_for_packet(websocket, packet_type, timeout=8):
    async def read():
        while True:
            packet = json.loads(await websocket.recv())
            if packet.get("type") == packet_type:
                return packet

    return await asyncio.wait_for(read(), timeout)


async def run(uri, connection_count):
    if not REDIS_URL:
        raise RuntimeError("MESH_REDIS_URL is not configured")
    suffix = secrets.token_hex(5)
    login = f"worker_smoke_{suffix}"
    password = secrets.token_urlsafe(24)
    relay = MeshRelayServer()
    ok, reason = relay.authenticate_account(
        login,
        password,
        f"bootstrap-{suffix}",
        "Realtime smoke",
    )
    if not ok:
        raise RuntimeError(f"could not create smoke account: {reason}")

    redis = redis_async.from_url(REDIS_URL, decode_responses=True)
    sockets = {}
    try:
        for index in range(connection_count):
            node_id = f"smoke-{suffix}-{index}"
            sockets[node_id] = await _connect(
                uri,
                login,
                password,
                node_id,
            )

        worker_nodes = {}
        for node_id in sockets:
            presence = await redis.hgetall(
                f"{REDIS_PREFIX}:presence:client:{node_id}"
            )
            worker_nodes.setdefault(presence.get("worker_id"), []).append(
                node_id
            )
        worker_nodes.pop(None, None)
        if len(worker_nodes) < 2:
            raise RuntimeError(
                f"connections reached only one worker: {worker_nodes}"
            )

        worker_ids = sorted(worker_nodes)
        source_node = worker_nodes[worker_ids[0]][0]
        destination_node = worker_nodes[worker_ids[1]][0]
        call_id = f"smoke-call-{suffix}"
        await sockets[source_node].send(
            json.dumps(
                {
                    "type": "call_offer",
                    "source_node": source_node,
                    "destination_node": destination_node,
                    "call_id": call_id,
                    "operation_id": f"smoke-offer-{suffix}",
                    "sdp": "realtime-smoke",
                }
            )
        )
        delivered = await _wait_for_packet(
            sockets[destination_node],
            "call_offer",
        )
        if delivered.get("call_id") != call_id:
            raise RuntimeError("cross-worker packet identity changed")

        result = {
            "ok": True,
            "workers": {
                worker_id: len(nodes)
                for worker_id, nodes in worker_nodes.items()
            },
            "source_worker": worker_ids[0],
            "destination_worker": worker_ids[1],
            "packet": "call_offer",
        }
        print(json.dumps(result, sort_keys=True))
    finally:
        await asyncio.gather(
            *(socket.close() for socket in sockets.values()),
            return_exceptions=True,
        )
        await redis.aclose()
        relay.delete_account(login, password)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--uri", default="ws://127.0.0.1:8765")
    parser.add_argument("--connections", type=int, default=12)
    args = parser.parse_args()
    asyncio.run(run(args.uri, max(4, args.connections)))


if __name__ == "__main__":
    main()
