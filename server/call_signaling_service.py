"""Entrypoint for the standalone MeshChat call signaling service."""

import asyncio
import signal

from aiohttp import web

from server.call_signaling import CallSignalingService, build_http_app
from server.config import (
    CALL_SIGNALING_ACTIVE_CALL_TTL_SECONDS,
    CALL_SIGNALING_CONSUMER_ID,
    CALL_SIGNALING_HEARTBEAT_TTL_SECONDS,
    CALL_SIGNALING_HOST,
    CALL_SIGNALING_PORT,
    REDIS_PREFIX,
    REDIS_URL,
)


async def main():
    service = CallSignalingService(
        REDIS_URL,
        prefix=REDIS_PREFIX,
        consumer_id=CALL_SIGNALING_CONSUMER_ID,
        heartbeat_ttl=CALL_SIGNALING_HEARTBEAT_TTL_SECONDS,
        active_call_ttl=CALL_SIGNALING_ACTIVE_CALL_TTL_SECONDS,
    )
    await service.start()
    runner = web.AppRunner(build_http_app(service))
    await runner.setup()
    site = web.TCPSite(runner, CALL_SIGNALING_HOST, CALL_SIGNALING_PORT)
    await site.start()
    task = asyncio.create_task(service.run(), name="call-signaling-consumer")
    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for current_signal in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(current_signal, stop_event.set)
        except NotImplementedError:
            pass
    print(
        "Call signaling service listening on "
        f"http://{CALL_SIGNALING_HOST}:{CALL_SIGNALING_PORT} "
        f"({CALL_SIGNALING_CONSUMER_ID})"
    )
    try:
        await stop_event.wait()
    finally:
        service.stop_event.set()
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
        await runner.cleanup()
        await service.close()


if __name__ == "__main__":
    asyncio.run(main())
