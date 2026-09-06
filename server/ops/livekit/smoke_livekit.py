"""Open two authenticated LiveKit signaling sessions without exposing secrets."""

import asyncio
import os
from pathlib import Path
from urllib.parse import urlencode

import websockets

try:
    from server.call_access import build_livekit_access_token, private_room_name
except ModuleNotFoundError:
    from call_access import build_livekit_access_token, private_room_name


def _load_env(path):
    for raw_line in Path(path).read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key, value)


async def _connect(url, token):
    query = urlencode(
        {
            "auto_subscribe": "1",
            "adaptive_stream": "1",
            "protocol": "15",
            "sdk": "python",
            "version": "smoke",
        }
    )
    websocket = await websockets.connect(
        f"{url}/rtc?{query}",
        additional_headers={"Authorization": f"Bearer {token}"},
        open_timeout=10,
        close_timeout=3,
        max_size=4 * 1024 * 1024,
    )
    first_message = await asyncio.wait_for(websocket.recv(), timeout=10)
    if not isinstance(first_message, bytes) or not first_message:
        await websocket.close()
        raise RuntimeError("LiveKit did not return a binary join response")
    return websocket


async def main():
    _load_env("/etc/mesh-messenger/livekit.env")
    api_key = os.environ["MESH_CALL_SFU_API_KEY"]
    api_secret = os.environ["MESH_CALL_SFU_API_SECRET"]
    url = os.environ["MESH_CALL_SFU_URL"]
    room = private_room_name("meshchat-livekit-smoke", api_secret)
    tokens = [
        build_livekit_access_token(
            api_key=api_key,
            api_secret=api_secret,
            room=room,
            identity=f"smoke-{index}",
            ttl_seconds=60,
        )
        for index in (1, 2)
    ]
    first = await _connect(url, tokens[0])
    try:
        second = await _connect(url, tokens[1])
        await second.close()
    finally:
        await first.close()
    print("LiveKit signaling smoke passed for two participants")


if __name__ == "__main__":
    asyncio.run(main())
