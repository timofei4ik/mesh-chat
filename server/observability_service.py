"""Low-overhead Prometheus endpoint for MeshChat production capacity."""

from __future__ import annotations

import asyncio
import os
import time

from aiohttp import web

from server.redis_client import create_async_redis, warm_async_redis


class MeshMetrics:
    def __init__(self, redis_url, prefix="meshchat"):
        self.redis_url = str(redis_url or "").strip()
        self.prefix = str(prefix or "meshchat").strip()
        self.redis = None
        self.started_at = time.time()

    async def start(self):
        self.redis = create_async_redis(
            self.redis_url,
            max_connections=8,
        )
        await warm_async_redis(self.redis, 8)
        await self.redis.ping()

    async def close(self):
        if self.redis is not None:
            await self.redis.aclose()

    async def _count_keys(self, pattern):
        total = 0
        async for _ in self.redis.scan_iter(match=pattern, count=500):
            total += 1
        return total

    async def collect(self):
        redis_up = 1
        try:
            await self.redis.ping()
            clients, services, workers, signaling = await asyncio.gather(
                self._count_keys(
                    f"{self.prefix}:presence:client:*"
                ),
                self._count_keys(
                    f"{self.prefix}:presence:service:*"
                ),
                self._count_keys(
                    f"{self.prefix}:worker:heartbeat:*"
                ),
                self._count_keys(
                    f"{self.prefix}:call:signaling:heartbeat:*"
                ),
            )
            active_calls_key = f"{self.prefix}:call:active:v2"
            await self.redis.zremrangebyscore(
                active_calls_key,
                "-inf",
                time.time(),
            )
            active_calls, signal_entries = await asyncio.gather(
                self.redis.zcard(active_calls_key),
                self.redis.xlen(f"{self.prefix}:call:signals"),
            )
            groups = await self.redis.xinfo_groups(
                f"{self.prefix}:call:signals"
            )
            call_pending = sum(
                int(group.get("pending") or 0)
                for group in groups
            )
        except Exception:
            redis_up = 0
            clients = services = workers = signaling = 0
            active_calls = signal_entries = call_pending = 0
        return {
            "redis_up": redis_up,
            "connected_clients": clients,
            "connected_services": services,
            "chat_workers": workers,
            "call_signaling_instances": signaling,
            "active_calls": active_calls,
            "call_signal_stream_entries": signal_entries,
            "call_signal_pending": call_pending,
            "uptime_seconds": int(time.time() - self.started_at),
        }

    async def prometheus(self):
        values = await self.collect()
        descriptions = {
            "redis_up": "Whether Redis coordination is reachable.",
            "connected_clients": "Current authenticated client connections.",
            "connected_services": "Current Mesh service connections.",
            "chat_workers": "Live Chat/Sync worker processes.",
            "call_signaling_instances": "Live call signaling consumers.",
            "active_calls": "Active call identifiers.",
            "call_signal_stream_entries": "Retained call signaling events.",
            "call_signal_pending": "Unacknowledged call signaling events.",
            "uptime_seconds": "Observability process uptime.",
        }
        lines = []
        for name, value in values.items():
            metric = f"meshchat_{name}"
            lines.extend(
                [
                    f"# HELP {metric} {descriptions[name]}",
                    f"# TYPE {metric} gauge",
                    f"{metric} {value}",
                ]
            )
        return "\n".join(lines) + "\n"


async def main():
    redis_url = os.environ.get("MESH_REDIS_URL", "").strip()
    if not redis_url:
        raise RuntimeError("MESH_REDIS_URL is required")
    metrics = MeshMetrics(
        redis_url,
        os.environ.get("MESH_REDIS_PREFIX", "meshchat"),
    )
    await metrics.start()

    async def health(_request):
        values = await metrics.collect()
        ok = bool(values["redis_up"])
        return web.json_response(
            {
                "ok": ok,
                "status": "ok" if ok else "degraded",
                **values,
            },
            status=200 if ok else 503,
        )

    async def prometheus(_request):
        return web.Response(
            text=await metrics.prometheus(),
            content_type="text/plain",
        )

    app = web.Application()
    app.router.add_get("/health", health)
    app.router.add_get("/metrics", prometheus)
    runner = web.AppRunner(app)
    await runner.setup()
    host = os.environ.get("MESH_METRICS_HOST", "127.0.0.1")
    port = int(os.environ.get("MESH_METRICS_PORT", "8780"))
    site = web.TCPSite(runner, host, port)
    await site.start()
    print(f"MeshChat metrics listening on http://{host}:{port}")
    try:
        await asyncio.Event().wait()
    finally:
        await runner.cleanup()
        await metrics.close()


if __name__ == "__main__":
    asyncio.run(main())
