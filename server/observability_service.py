"""Low-overhead Prometheus endpoint for MeshChat production capacity."""

from __future__ import annotations

import asyncio
import os
import time
import json
from collections import Counter
from redis.exceptions import ResponseError

from aiohttp import web

from server.redis_client import create_async_redis, warm_async_redis
from server.runtime_metrics import RuntimeMetrics


class MeshMetrics:
    def __init__(self, redis_url, prefix="meshchat"):
        self.redis_url = str(redis_url or "").strip()
        self.prefix = str(prefix or "meshchat").strip()
        self.redis = None
        self.started_at = time.time()
        self.worker_samples = {}

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
        runtime = Counter()
        self.worker_samples = {}
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
            try:
                groups = await self.redis.xinfo_groups(f"{self.prefix}:call:signals")
            except ResponseError as error:
                if "no such key" not in str(error).lower():
                    raise
                groups = []
            call_pending = sum(
                int(group.get("pending") or 0)
                for group in groups
            )
            allowed = set(RuntimeMetrics().snapshot()) | {
                "delivery_queue_depth", "delivery_oldest_seconds",
                "delivery_intent_accounts", "delivery_intent_oldest_seconds",
            }
            async for key in self.redis.scan_iter(
                    match=f"{self.prefix}:worker:metrics:*", count=100):
                values = await self.redis.hgetall(key)
                worker = key.removeprefix(f"{self.prefix}:worker:metrics:")
                self.worker_samples[worker] = {
                    name: float(raw) for name, raw in values.items() if name in allowed
                }
                for name, raw in values.items():
                    if name not in allowed:
                        continue
                    value = float(raw)
                    if name in {"event_loop_lag_seconds", "delivery_queue_depth", "delivery_oldest_seconds",
                                "delivery_intent_accounts", "delivery_intent_oldest_seconds"}:
                        runtime[name] = max(runtime[name], value)
                    else:
                        runtime[name] += value
        except Exception:
            redis_up = 0
            clients = services = workers = signaling = 0
            active_calls = signal_entries = call_pending = 0
            runtime.clear()
            self.worker_samples.clear()
        return {
            **runtime,
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
            if name in RuntimeMetrics.COUNTERS:
                continue
            if "_seconds_bucket_" in name or name.endswith(("_seconds_count", "_seconds_sum")):
                continue
            metric = f"meshchat_{name}"
            lines.extend(
                [
                    f"# HELP {metric} {descriptions.get(name, name.replace('_', ' '))}",
                    f"# TYPE {metric} gauge",
                    f"{metric} {value}",
                ]
            )
        for name in sorted(RuntimeMetrics.COUNTERS):
            metric = f"meshchat_{name}"
            lines.append(f"# TYPE {metric} counter")
            for worker, sample in self.worker_samples.items():
                lines.append(f'{metric}{{worker={json.dumps(worker)}}} {sample.get(name, 0)}')
        # Separate worker labels preserve reset detection when just one process restarts.
        for name in RuntimeMetrics.TIMINGS:
            metric = f"meshchat_{name}_seconds"
            lines.append(f"# TYPE {metric} histogram")
            for worker, sample in self.worker_samples.items():
                label = f'worker={json.dumps(worker)}'
                for upper in RuntimeMetrics.BUCKETS:
                    value = sample.get(f"{name}_seconds_bucket_{upper}", 0)
                    lines.append(f'{metric}_bucket{{{label},le="{upper}"}} {value}')
                count = sample.get(f"{name}_seconds_count", 0)
                lines.append(f'{metric}_bucket{{{label},le="+Inf"}} {count}')
                lines.append(f'{metric}_count{{{label}}} {count}')
                lines.append(f'{metric}_sum{{{label}}} {sample.get(f"{name}_seconds_sum", 0)}')
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
