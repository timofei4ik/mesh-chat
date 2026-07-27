"""MeshChat WebSocket load generator for 1,000-5,000 virtual clients."""

from __future__ import annotations

import argparse
import asyncio
import json
import math
import random
import statistics
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path

import websockets

from server.server_protocol import (
    APP_VERSION,
    MIN_SUPPORTED_PROTOCOL_VERSION,
    PROTOCOL_VERSION,
)


@dataclass
class Result:
    connected: int = 0
    failed: int = 0
    messages: int = 0
    reconnects: int = 0
    reconnect_failed: int = 0
    latencies_ms: list[float] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)


def percentile(values, rank):
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(
        len(ordered) - 1,
        max(0, math.ceil(rank * len(ordered)) - 1),
    )
    return ordered[index]


def load_accounts(path, login, password):
    if not path:
        return [{"login": login, "password": password}]
    payload = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(payload, list) or not payload:
        raise ValueError("accounts file must contain a non-empty JSON list")
    return payload


class VirtualClient:
    def __init__(self, index, args, account, result):
        self.index = index
        self.args = args
        self.account = account
        self.result = result
        self.node_id = f"load-{args.run_id}-{index:05d}"
        self.websocket = None
        self.reader = None

    async def connect(self):
        started = time.perf_counter()
        self.websocket = await websockets.connect(
            self.args.uri,
            max_size=16 * 1024 * 1024,
            ping_interval=20,
            ping_timeout=20,
            open_timeout=self.args.connect_timeout,
            close_timeout=2,
        )
        await self.websocket.send(
            json.dumps(
                {
                    "type": "server_hello",
                    "node_id": self.node_id,
                    "username": self.node_id,
                    "display_name": self.node_id,
                    "login": self.account.get("login", ""),
                    "password": self.account.get("password", ""),
                    "server_token": self.args.server_token,
                    "app_version": APP_VERSION,
                    "protocol_version": PROTOCOL_VERSION,
                    "min_protocol_version": MIN_SUPPORTED_PROTOCOL_VERSION,
                    "register_if_missing": False,
                    "supports_sync_v2": True,
                    "supports_sync_v2_delta": True,
                    "sync_cursor": 0,
                    "supports_offline_packet_ack": True,
                    "supports_mutation_ack": True,
                    "supports_account_live_fanout": True,
                    "supports_multi_device_state": True,
                },
                separators=(",", ":"),
            )
        )
        deadline = time.monotonic() + self.args.connect_timeout
        while time.monotonic() < deadline:
            packet = json.loads(
                await asyncio.wait_for(
                    self.websocket.recv(),
                    timeout=max(0.1, deadline - time.monotonic()),
                )
            )
            if packet.get("type") == "server_error":
                raise RuntimeError(
                    f"{packet.get('code')}: {packet.get('message')}"
                )
            if packet.get("type") == "server_welcome":
                break
        else:
            raise TimeoutError("server_welcome timeout")
        self.result.connected += 1
        self.result.latencies_ms.append(
            (time.perf_counter() - started) * 1000
        )
        self.reader = asyncio.create_task(self._read())

    async def _read(self):
        try:
            async for _ in self.websocket:
                self.result.messages += 1
        except Exception:
            pass

    async def reconnect(self):
        await self.close()
        self.result.reconnects += 1
        await self.connect()

    async def close(self):
        if self.websocket is not None:
            await self.websocket.close()
        if self.reader is not None:
            self.reader.cancel()
            await asyncio.gather(self.reader, return_exceptions=True)
        self.websocket = None
        self.reader = None


async def run(args):
    if not 1 <= args.clients <= 5000:
        raise ValueError("--clients must be between 1 and 5000")
    accounts = load_accounts(
        args.accounts_file,
        args.login,
        args.password,
    )
    if not accounts[0].get("login") or not accounts[0].get("password"):
        raise ValueError("provide --login/--password or --accounts-file")
    result = Result()
    clients = []
    interval = 1.0 / max(1.0, args.ramp_per_second)
    started = time.monotonic()

    async def connect_one(index):
        account = accounts[index % len(accounts)]
        client = VirtualClient(index, args, account, result)
        try:
            await client.connect()
            clients.append(client)
        except Exception as error:
            result.failed += 1
            if len(result.errors) < 20:
                result.errors.append(f"{index}: {error}")

    pending = set()
    for index in range(args.clients):
        pending.add(asyncio.create_task(connect_one(index)))
        if len(pending) >= args.connect_concurrency:
            done, pending = await asyncio.wait(
                pending,
                return_when=asyncio.FIRST_COMPLETED,
            )
        await asyncio.sleep(interval)
    if pending:
        await asyncio.gather(*pending)

    ramp_seconds = time.monotonic() - started
    if args.reconnect_percent and clients:
        reconnect_count = max(
            1,
            round(len(clients) * args.reconnect_percent / 100),
        )
        chosen = random.sample(
            clients,
            min(reconnect_count, len(clients)),
        )
        reconnect_results = await asyncio.gather(
            *(client.reconnect() for client in chosen),
            return_exceptions=True,
        )
        for outcome in reconnect_results:
            if isinstance(outcome, Exception):
                result.reconnect_failed += 1
                if len(result.errors) < 20:
                    result.errors.append(f"reconnect: {outcome}")
    await asyncio.sleep(args.hold_seconds)
    await asyncio.gather(*(client.close() for client in clients))
    total_seconds = time.monotonic() - started
    report = {
        "requested_clients": args.clients,
        "connected": len(clients),
        "successful_connection_attempts": result.connected,
        "failed": result.failed,
        "received_messages": result.messages,
        "reconnects": result.reconnects,
        "reconnect_failed": result.reconnect_failed,
        "ramp_seconds": round(ramp_seconds, 3),
        "total_seconds": round(total_seconds, 3),
        "connect_latency_ms": {
            "mean": round(
                statistics.fmean(result.latencies_ms)
                if result.latencies_ms
                else 0,
                2,
            ),
            "p50": round(percentile(result.latencies_ms, 0.50), 2),
            "p95": round(percentile(result.latencies_ms, 0.95), 2),
            "p99": round(percentile(result.latencies_ms, 0.99), 2),
            "max": round(max(result.latencies_ms, default=0), 2),
        },
        "errors": result.errors,
    }
    print(json.dumps(report, indent=2, ensure_ascii=False))
    if result.failed or result.reconnect_failed:
        raise SystemExit(2)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--uri", default="wss://meshchat-losa.ru/ws")
    parser.add_argument("--clients", type=int, default=1000)
    parser.add_argument("--ramp-per-second", type=float, default=100)
    parser.add_argument("--connect-concurrency", type=int, default=200)
    parser.add_argument("--connect-timeout", type=float, default=20)
    parser.add_argument("--hold-seconds", type=float, default=60)
    parser.add_argument("--reconnect-percent", type=float, default=10)
    parser.add_argument("--login", default="")
    parser.add_argument("--password", default="")
    parser.add_argument("--server-token", default="")
    parser.add_argument("--accounts-file", default="")
    parser.add_argument("--run-id", default=uuid.uuid4().hex[:10])
    asyncio.run(run(parser.parse_args()))


if __name__ == "__main__":
    main()
