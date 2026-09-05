"""Isolated relay entrypoint: no billing, push or scheduler background services."""
import asyncio
import json
import os
import socket
from pathlib import Path
from urllib.parse import urlparse

from server.ops.reliability_lab.queue_probe import validate_url


async def main():
    validate_url(os.environ["MESH_DATABASE_URL"])
    if not os.environ.get("MESH_REDIS_PREFIX", "").startswith("meshchat-lab-"):
        raise RuntimeError("Refusing non-lab Redis prefix")
    broker = urlparse(os.environ.get("MESH_REDIS_URL", ""))
    if (broker.scheme != "redis" or broker.hostname != "127.0.0.1"
            or broker.port != 16379):
        raise RuntimeError("Only the loopback lab Redis port is allowed")
    from server.server import MeshRelayServer
    import websockets
    relay = MeshRelayServer()
    await relay.start_realtime()
    connections = set()
    metrics = {"blocked_sends": 0, "max_send_ms": 0, "buffer_peak_bytes": 0}
    async def handler(websocket):
        connections.add(websocket)
        if os.environ.get("MESH_LAB_SNDBUF"):
            websocket.transport.get_extra_info("socket").setsockopt(
                socket.SOL_SOCKET, socket.SO_SNDBUF, int(os.environ["MESH_LAB_SNDBUF"]))
        original_send = websocket.send
        async def measured_send(*args, **kwargs):
            started = asyncio.get_running_loop().time()
            try:
                return await original_send(*args, **kwargs)
            finally:
                duration = (asyncio.get_running_loop().time() - started) * 1000
                metrics["max_send_ms"] = max(metrics["max_send_ms"], round(duration, 1))
                metrics["blocked_sends"] += int(duration > 100)
        websocket.send = measured_send
        try:
            await relay.handler(websocket)
        finally:
            connections.discard(websocket)
    async def sample():
        while True:
            for connection in list(connections):
                metrics["buffer_peak_bytes"] = max(metrics["buffer_peak_bytes"],
                    connection.transport.get_write_buffer_size())
            Path(os.environ["MESH_LAB_READY"]).with_suffix(".metrics.json").write_text(
                json.dumps(metrics), encoding="utf-8")
            await asyncio.sleep(.2)
    sampler = asyncio.create_task(sample())
    try:
        async with websockets.serve(handler, "127.0.0.1", int(os.environ["MESH_LAB_PORT"]),
                                    max_size=128 * 1024 * 1024, write_limit=16384,
                                    ping_timeout=90, compression=None) as server:
            Path(os.environ["MESH_LAB_READY"]).write_text(json.dumps({
                "port": server.sockets[0].getsockname()[1], "pid": os.getpid(),
            }), encoding="utf-8")
            await asyncio.Event().wait()
    finally:
        sampler.cancel()
        await asyncio.gather(sampler, return_exceptions=True)
        await relay.stop_realtime()
        relay.db.close()


if __name__ == "__main__":
    asyncio.run(main())
