"""Redis Stream based call signaling separated from Chat/Sync workers."""

from __future__ import annotations

import asyncio
import json
import time
from collections import Counter

from server.redis_client import create_async_redis, warm_async_redis

class CallSignalingPublisher:
    """Small producer used by Chat/Sync workers.

    A heartbeat gate keeps the migration fail-safe: when no dedicated consumer
    is alive, callers transparently fall back to the legacy in-worker route.
    """

    def __init__(
        self,
        redis_url="",
        prefix="meshchat",
        enabled=False,
        stream_maxlen=100000,
    ):
        self.redis_url = str(redis_url or "").strip()
        self.prefix = str(prefix or "meshchat").strip()
        self.configured = bool(enabled and self.redis_url)
        self.stream_maxlen = int(stream_maxlen)
        self.redis = None

    @property
    def enabled(self):
        return bool(self.configured and self.redis is not None)

    @property
    def stream_key(self):
        return f"{self.prefix}:call:signals"

    @property
    def heartbeat_key(self):
        return f"{self.prefix}:call:signaling:heartbeat"

    async def start(self):
        if not self.configured:
            return
        self.redis = create_async_redis(
            self.redis_url,
            max_connections=8,
        )
        await warm_async_redis(self.redis, 8)
        await self.redis.ping()

    async def stop(self):
        if self.redis is not None:
            await self.redis.aclose()
        self.redis = None

    async def submit(self, packet):
        if not self.enabled:
            return False
        try:
            if not await self.redis.exists(self.heartbeat_key):
                return False
            await self.redis.xadd(
                self.stream_key,
                {
                    "packet": json.dumps(
                        packet,
                        ensure_ascii=False,
                        separators=(",", ":"),
                    ),
                    "queued_at": f"{time.time():.6f}",
                },
                maxlen=self.stream_maxlen,
                approximate=True,
            )
            return True
        except Exception as error:
            print("Call signaling enqueue failed; using local fallback:", error)
            return False


class CallSignalingService:
    GROUP = "mesh-call-signaling"

    def __init__(
        self,
        redis_url,
        prefix="meshchat",
        consumer_id="call-0",
        heartbeat_ttl=15,
        active_call_ttl=86400,
    ):
        self.redis_url = str(redis_url or "").strip()
        self.prefix = str(prefix or "meshchat").strip()
        self.consumer_id = str(consumer_id or "call-0").strip()
        self.heartbeat_ttl = int(heartbeat_ttl)
        self.active_call_ttl = max(60, int(active_call_ttl))
        self.redis = None
        self.stop_event = asyncio.Event()
        self.metrics = Counter()
        self.started_at = time.time()

    @property
    def stream_key(self):
        return f"{self.prefix}:call:signals"

    @property
    def heartbeat_key(self):
        return f"{self.prefix}:call:signaling:heartbeat"

    def _presence_key(self, node_id):
        return f"{self.prefix}:presence:client:{node_id}"

    def _account_key(self, login):
        return f"{self.prefix}:account:client:{login}:nodes"

    def _worker_channel(self, worker_id):
        return f"{self.prefix}:worker:{worker_id}"

    @property
    def active_calls_key(self):
        return f"{self.prefix}:call:active:v2"

    async def start(self):
        if not self.redis_url:
            raise RuntimeError("MESH_REDIS_URL is required for call signaling")
        self.redis = create_async_redis(
            self.redis_url,
            max_connections=16,
        )
        await warm_async_redis(self.redis, 16)
        await self.redis.ping()
        try:
            await self.redis.xgroup_create(
                self.stream_key,
                self.GROUP,
                id="0",
                mkstream=True,
            )
        except Exception as error:
            if "BUSYGROUP" not in str(error):
                raise

    async def close(self):
        self.stop_event.set()
        if self.redis is not None:
            await self.redis.delete(
                f"{self.heartbeat_key}:{self.consumer_id}"
            )
            await self.redis.aclose()
        self.redis = None

    async def run(self):
        heartbeat = asyncio.create_task(
            self._heartbeat(),
            name=f"call-heartbeat:{self.consumer_id}",
        )
        reclaim = asyncio.create_task(
            self._reclaim_pending(),
            name=f"call-reclaim:{self.consumer_id}",
        )
        try:
            while not self.stop_event.is_set():
                records = await self.redis.xreadgroup(
                    self.GROUP,
                    self.consumer_id,
                    {self.stream_key: ">"},
                    count=128,
                    block=1000,
                )
                for _, messages in records:
                    for message_id, fields in messages:
                        await self._consume(message_id, fields)
        finally:
            heartbeat.cancel()
            reclaim.cancel()
            await asyncio.gather(heartbeat, reclaim, return_exceptions=True)

    async def _consume(self, message_id, fields):
        self.metrics["received_total"] += 1
        try:
            packet = json.loads(fields.get("packet") or "{}")
            await self.route(packet)
            await self.redis.xack(self.stream_key, self.GROUP, message_id)
            self.metrics["processed_total"] += 1
        except Exception as error:
            self.metrics["errors_total"] += 1
            print(f"Call signaling packet {message_id} failed:", error)

    async def route(self, packet):
        destination = str(packet.get("destination_node") or "").strip()
        if not destination or destination.upper() == "SERVER":
            self.metrics["invalid_total"] += 1
            return False

        target_nodes = [destination]
        destination_presence = await self.redis.hgetall(
            self._presence_key(destination)
        )
        destination_login = str(
            destination_presence.get("login") or ""
        ).strip().lower()
        packet_type = str(packet.get("type") or "")
        exact_device_signal = bool(packet.get("group_id")) or packet_type in {
            "call_handoff_request",
            "call_handoff_accept",
        } or (
            packet_type == "call_offer"
            and bool(str(packet.get("handoff_from_call_id") or "").strip())
        )
        if destination_login and not exact_device_signal:
            target_nodes.extend(
                await self.redis.smembers(
                    self._account_key(destination_login)
                )
            )

        source_node = str(packet.get("source_node") or "").strip()
        delivered = False
        delivered_nodes = set()
        for target_node in target_nodes:
            target_node = str(target_node or "").strip()
            if (
                not target_node
                or target_node == source_node
                or target_node in delivered_nodes
            ):
                continue
            presence = await self.redis.hgetall(
                self._presence_key(target_node)
            )
            worker_id = str(presence.get("worker_id") or "")
            session_id = str(presence.get("session_id") or "")
            if not worker_id or not session_id:
                continue
            routed = packet
            if target_node != destination:
                routed = {
                    **packet,
                    "destination_node": target_node,
                    "original_destination_node": destination,
                }
            subscribers = await self.redis.publish(
                self._worker_channel(worker_id),
                json.dumps(
                    {
                        "action": "deliver",
                        "node_id": target_node,
                        "kind": "client",
                        "session_id": session_id,
                        "required_capability": "",
                        "packet": routed,
                    },
                    ensure_ascii=False,
                    separators=(",", ":"),
                ),
            )
            if subscribers:
                delivered = True
                delivered_nodes.add(target_node)
                self.metrics["deliveries_total"] += 1

        call_id = str(packet.get("call_id") or "").strip()
        packet_type = str(packet.get("type") or "")
        if call_id and packet_type == "call_end":
            await self.redis.zrem(self.active_calls_key, call_id)
        elif call_id:
            await self.redis.zadd(
                self.active_calls_key,
                {call_id: time.time() + self.active_call_ttl},
            )
        if not delivered:
            self.metrics["offline_total"] += 1
        return delivered

    async def _heartbeat(self):
        instance_key = f"{self.heartbeat_key}:{self.consumer_id}"
        interval = max(1, self.heartbeat_ttl // 3)
        while not self.stop_event.is_set():
            pipeline = self.redis.pipeline(transaction=False)
            pipeline.set(
                instance_key,
                f"{time.time():.6f}",
                ex=self.heartbeat_ttl,
            )
            pipeline.set(
                self.heartbeat_key,
                f"{time.time():.6f}",
                ex=self.heartbeat_ttl,
            )
            await pipeline.execute()
            try:
                await asyncio.wait_for(
                    self.stop_event.wait(),
                    timeout=interval,
                )
            except asyncio.TimeoutError:
                pass

    async def _reclaim_pending(self):
        await asyncio.sleep(10)
        while not self.stop_event.is_set():
            try:
                claimed = await self.redis.xautoclaim(
                    self.stream_key,
                    self.GROUP,
                    self.consumer_id,
                    min_idle_time=30_000,
                    start_id="0-0",
                    count=64,
                )
                messages = claimed[1] if len(claimed) > 1 else []
                for message_id, fields in messages:
                    self.metrics["reclaimed_total"] += 1
                    await self._consume(message_id, fields)
            except Exception as error:
                self.metrics["reclaim_errors_total"] += 1
                print("Call signaling reclaim failed:", error)
            try:
                await asyncio.wait_for(
                    self.stop_event.wait(),
                    timeout=30,
                )
            except asyncio.TimeoutError:
                pass

    async def health_payload(self):
        try:
            redis_ok = bool(await self.redis.ping())
        except Exception:
            redis_ok = False
        return {
            "ok": redis_ok,
            "status": "ok" if redis_ok else "degraded",
            "redis": redis_ok,
            "consumer": self.consumer_id,
            "uptime_seconds": int(time.time() - self.started_at),
        }

    async def prometheus(self):
        await self.redis.zremrangebyscore(
            self.active_calls_key,
            "-inf",
            time.time(),
        )
        active = await self.redis.zcard(self.active_calls_key)
        queue = await self.redis.xlen(self.stream_key)
        lines = [
            "# HELP meshchat_call_active Active call identifiers.",
            "# TYPE meshchat_call_active gauge",
            f"meshchat_call_active {active}",
            "# HELP meshchat_call_signal_stream_entries Entries retained in the signaling stream.",
            "# TYPE meshchat_call_signal_stream_entries gauge",
            f"meshchat_call_signal_stream_entries {queue}",
        ]
        for name, value in sorted(self.metrics.items()):
            metric = f"meshchat_call_signal_{name}"
            lines.extend(
                [
                    f"# TYPE {metric} counter",
                    f"{metric} {value}",
                ]
            )
        return "\n".join(lines) + "\n"


def build_http_app(service):
    from aiohttp import web

    async def health(_request):
        payload = await service.health_payload()
        status = 200 if payload["status"] == "ok" else 503
        return web.json_response(payload, status=status)

    async def metrics(_request):
        return web.Response(
            text=await service.prometheus(),
            content_type="text/plain",
        )

    app = web.Application()
    app.router.add_get("/health", health)
    app.router.add_get("/ready", health)
    app.router.add_get("/metrics", metrics)
    return app
