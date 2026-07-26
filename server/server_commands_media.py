try:
    from server.server_command_bus import account_login, send_json
except ModuleNotFoundError:
    from server_command_bus import account_login, send_json


async def _media_download_request(server, packet, context):
    request_id = str(packet.get("request_id") or "").strip()
    file_id = str(packet.get("file_id") or "").strip()
    login = account_login(server, context.node_id)
    issued = server.issue_media_download(login, file_id)
    if not issued:
        await send_json(
            context.websocket,
            {
                "type": "media_download_ready",
                "request_id": request_id,
                "file_id": file_id,
                "ok": False,
                "reason": "media_not_found_or_forbidden",
            },
        )
        return
    await send_json(
        context.websocket,
        {
            "type": "media_download_ready",
            "request_id": request_id,
            "file_id": issued["file_id"],
            "media_id": issued["media_id"],
            "file_sha256": issued["sha256"],
            "file_size": issued["size_bytes"],
            "group_id": issued["group_id"],
            "group_key_id": issued["group_key_id"],
            "download_url": issued["download_url"],
            "download_token": issued["download_token"],
            "expires_at": issued["expires_at"],
            "ok": True,
        },
    )


def register_media_commands(registry):
    registry.register("media_download_request", _media_download_request)
