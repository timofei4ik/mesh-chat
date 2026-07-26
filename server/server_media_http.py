from pathlib import Path
from urllib.parse import quote

try:
    from aiohttp import web
except ModuleNotFoundError:
    web = None

try:
    from server.config import MEDIA_HTTP_HOST, MEDIA_HTTP_PORT
except ModuleNotFoundError:
    from config import MEDIA_HTTP_HOST, MEDIA_HTTP_PORT


class MediaHttpServer:
    def __init__(self, relay):
        self.relay = relay
        self.runner = None
        self.site = None

    async def start(self):
        if web is None:
            raise RuntimeError("aiohttp is required for media delivery")
        app = web.Application(client_max_size=1024)
        app.router.add_get("/media/health", self._health)
        app.router.add_get(
            "/media/v2/{file_id}",
            self._download,
            allow_head=True,
        )
        self.runner = web.AppRunner(app, access_log=None)
        await self.runner.setup()
        self.site = web.TCPSite(
            self.runner,
            MEDIA_HTTP_HOST,
            MEDIA_HTTP_PORT,
        )
        await self.site.start()
        return True

    async def close(self):
        if self.runner is not None:
            await self.runner.cleanup()
            self.runner = None
            self.site = None

    async def _health(self, request):
        return web.json_response({"ok": True, "version": 2})

    async def _download(self, request):
        authorization = request.headers.get("Authorization", "")
        if not authorization.startswith("Bearer "):
            raise web.HTTPUnauthorized()
        file_id = request.match_info.get("file_id", "")
        media = self.relay.authorize_media_download(
            authorization[7:].strip(),
            file_id,
        )
        if not media:
            raise web.HTTPForbidden()

        headers = {
            "Accept-Ranges": "bytes",
            "Cache-Control": "private, no-store",
            "ETag": f'"{media["media_id"]}"',
            "X-Content-Type-Options": "nosniff",
            "Content-Disposition": (
                "inline; filename*=UTF-8''"
                + quote(media["filename"] or "meshchat-file", safe="")
            ),
        }
        storage_path = media["storage_path"]
        if storage_path and Path(storage_path).is_file():
            return web.FileResponse(
                Path(storage_path),
                headers=headers,
            )

        try:
            payload = bytes.fromhex(media["inline_hex"])
        except ValueError:
            raise web.HTTPInternalServerError()
        status, start, end = self._requested_range(
            request.headers.get("Range", ""),
            len(payload),
        )
        if status == 416:
            raise web.HTTPRequestRangeNotSatisfiable(
                headers={"Content-Range": f"bytes */{len(payload)}"}
            )
        selected = payload[start : end + 1]
        headers["Content-Length"] = str(len(selected))
        if status == 206:
            headers["Content-Range"] = f"bytes {start}-{end}/{len(payload)}"
        if request.method == "HEAD":
            selected = b""
        return web.Response(
            body=selected,
            status=status,
            headers=headers,
            content_type="application/octet-stream",
        )

    @staticmethod
    def _requested_range(value, size):
        if not value:
            return 200, 0, max(0, size - 1)
        if not value.startswith("bytes=") or "," in value or size <= 0:
            return 416, 0, 0
        raw_start, separator, raw_end = value[6:].partition("-")
        if not separator:
            return 416, 0, 0
        try:
            if raw_start:
                start = int(raw_start)
                end = int(raw_end) if raw_end else size - 1
            else:
                suffix = int(raw_end)
                if suffix <= 0:
                    return 416, 0, 0
                start = max(0, size - suffix)
                end = size - 1
        except ValueError:
            return 416, 0, 0
        if start < 0 or start >= size or end < start:
            return 416, 0, 0
        return 206, start, min(end, size - 1)
