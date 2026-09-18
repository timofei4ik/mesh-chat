"""Account-private encrypted draft attachments, transferred in bounded chunks."""
import asyncio
import hashlib
from pathlib import Path
import re
import os
import uuid

try:
    from server.server_command_bus import account_login, send_json
except ModuleNotFoundError:
    from server_command_bus import account_login, send_json


def _chunk(server, login, packet):
    blob = str(packet.get("blob_id") or "")
    index = packet.get("index")
    if not re.fullmatch(r"[a-f0-9-]{36}", blob) or type(index) is not int or not 0 <= index < 1024:
        raise ValueError("Invalid draft attachment")
    root = Path(getattr(server, "draft_blob_root", Path(__file__).resolve().parent.parent / "data" / "draft_attachments"))
    owner = root / hashlib.sha256(login.encode()).hexdigest()
    directory = owner / blob
    path = directory / str(index)
    if packet.get("type") == "draft_blob_get":
        return {"data": path.read_text(encoding="utf-8")}
    value = packet.get("data")
    if not isinstance(value, str) or not 0 < len(value.encode()) <= 192 * 1024:
        raise ValueError("Invalid draft chunk size")
    directory.mkdir(parents=True, exist_ok=True)
    if sum(p.stat().st_size for p in owner.glob("*/*") if p.is_file()) + len(value.encode()) > 512 * 1024 * 1024:
        raise ValueError("Draft attachment storage limit reached")
    # Readers never see partially written ciphertext, including upload retries.
    temporary = directory / f".{uuid.uuid4()}.tmp"
    try:
        with temporary.open("x", encoding="utf-8") as stream:
            stream.write(value)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
    return {}


async def handle_draft_blob(server, packet, context):
    login = account_login(server, context.node_id).strip().lower()
    result = {"type": "draft_blob_result", "request_id": packet.get("request_id"), "ok": False}
    try:
        if not login or context.is_service_connection:
            raise ValueError("Authentication required")
        result.update(await asyncio.to_thread(_chunk, server, login, packet))
        result["ok"] = True
    except (OSError, ValueError) as error:
        result["error"] = str(error) if isinstance(error, ValueError) else "Draft attachment unavailable"
    await send_json(context.websocket, result)


def register_draft_commands(registry):
    registry.register("draft_blob_put", handle_draft_blob)
    registry.register("draft_blob_get", handle_draft_blob)
