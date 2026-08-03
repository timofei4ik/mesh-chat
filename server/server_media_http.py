from collections import Counter
from pathlib import Path
import time
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
        self._metrics = Counter()
        self._active_requests = 0
        self._started_at = time.monotonic()

    async def start(self):
        if web is None:
            raise RuntimeError("aiohttp is required for media delivery")
        app = web.Application(client_max_size=1024)
        app.router.add_get("/media/health", self._health)
        app.router.add_get("/media/metrics", self._prometheus)
        app.router.add_get("/metrics", self._prometheus)
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
        try:
            health = self.relay.media_delivery_health()
        except Exception as error:
            return web.json_response(
                {
                    "ok": False,
                    "version": 3,
                    "error": type(error).__name__,
                },
                status=503,
            )
        health["metrics"] = self.metrics_snapshot()
        return web.json_response(health)

    async def _prometheus(self, request):
        return web.Response(
            text=self.prometheus_text(),
            content_type="text/plain",
            charset="utf-8",
        )

    async def _download(self, request):
        self._metrics["requests_total"] += 1
        self._active_requests += 1
        try:
            authorization = request.headers.get("Authorization", "")
            if not authorization.startswith("Bearer "):
                self._metrics["unauthorized_total"] += 1
                raise web.HTTPUnauthorized()
            file_id = request.match_info.get("file_id", "")
            media = self.relay.authorize_media_download(
                authorization[7:].strip(),
                file_id,
            )
            if not media:
                self._metrics["forbidden_total"] += 1
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
            range_header = request.headers.get("Range", "")
            object_path = self.relay.media_object_storage.resolve(
                media["storage_path"],
                media["media_id"],
            )
            if object_path:
                size = object_path.stat().st_size
                status, start, end = self._requested_range(range_header, size)
                if status == 416:
                    self._metrics["invalid_range_total"] += 1
                    raise web.HTTPRequestRangeNotSatisfiable(
                        headers={"Content-Range": f"bytes */{size}"}
                    )
                self._record_download_response(
                    status,
                    end - start + 1,
                    "object",
                    request.method == "HEAD",
                )
                return web.FileResponse(object_path, headers=headers)

            try:
                payload = bytes.fromhex(media["inline_hex"])
            except ValueError:
                self._metrics["invalid_media_total"] += 1
                raise web.HTTPInternalServerError()
            status, start, end = self._requested_range(
                range_header,
                len(payload),
            )
            if status == 416:
                self._metrics["invalid_range_total"] += 1
                raise web.HTTPRequestRangeNotSatisfiable(
                    headers={"Content-Range": f"bytes */{len(payload)}"}
                )
            selected = payload[start : end + 1]
            headers["Content-Length"] = str(len(selected))
            if status == 206:
                headers["Content-Range"] = f"bytes {start}-{end}/{len(payload)}"
            self._record_download_response(
                status,
                len(selected),
                "inline",
                request.method == "HEAD",
            )
            if request.method == "HEAD":
                selected = b""
            return web.Response(
                body=selected,
                status=status,
                headers=headers,
                content_type="application/octet-stream",
            )
        except web.HTTPException:
            raise
        except Exception:
            self._metrics["server_errors_total"] += 1
            raise
        finally:
            self._active_requests = max(0, self._active_requests - 1)

    def _record_download_response(
        self,
        status,
        byte_count,
        storage_kind,
        is_head=False,
    ):
        self._metrics["authorized_total"] += 1
        self._metrics[f"{storage_kind}_responses_total"] += 1
        if status == 206:
            self._metrics["range_requests_total"] += 1
        if not is_head:
            self._metrics["response_bytes_total"] += max(0, int(byte_count))

    def metrics_snapshot(self):
        return {
            "requests_total": int(self._metrics["requests_total"]),
            "authorized_total": int(self._metrics["authorized_total"]),
            "range_requests_total": int(
                self._metrics["range_requests_total"]
            ),
            "response_bytes_total": int(
                self._metrics["response_bytes_total"]
            ),
            "errors_total": int(
                self._metrics["unauthorized_total"]
                + self._metrics["forbidden_total"]
                + self._metrics["invalid_range_total"]
                + self._metrics["invalid_media_total"]
                + self._metrics["server_errors_total"]
            ),
            "unauthorized_total": int(
                self._metrics["unauthorized_total"]
            ),
            "forbidden_total": int(self._metrics["forbidden_total"]),
            "invalid_range_total": int(
                self._metrics["invalid_range_total"]
            ),
            "invalid_media_total": int(
                self._metrics["invalid_media_total"]
            ),
            "server_errors_total": int(
                self._metrics["server_errors_total"]
            ),
            "active_requests": int(self._active_requests),
        }

    def prometheus_text(self):
        values = {
            "mesh_media_requests_total": self._metrics["requests_total"],
            "mesh_media_authorized_total": self._metrics["authorized_total"],
            "mesh_media_range_requests_total": self._metrics[
                "range_requests_total"
            ],
            "mesh_media_response_bytes_total": self._metrics[
                "response_bytes_total"
            ],
            "mesh_media_object_responses_total": self._metrics[
                "object_responses_total"
            ],
            "mesh_media_inline_responses_total": self._metrics[
                "inline_responses_total"
            ],
            "mesh_media_unauthorized_total": self._metrics[
                "unauthorized_total"
            ],
            "mesh_media_forbidden_total": self._metrics["forbidden_total"],
            "mesh_media_invalid_range_total": self._metrics[
                "invalid_range_total"
            ],
            "mesh_media_invalid_media_total": self._metrics[
                "invalid_media_total"
            ],
            "mesh_media_server_errors_total": self._metrics[
                "server_errors_total"
            ],
            "mesh_media_active_requests": self._active_requests,
            "mesh_media_uptime_seconds": max(
                0,
                int(time.monotonic() - self._started_at),
            ),
        }
        lines = [
            "# HELP mesh_media_requests_total Media download requests.",
            "# TYPE mesh_media_requests_total counter",
        ]
        lines.extend(f"{name} {int(value)}" for name, value in values.items())
        return "\n".join(lines) + "\n"

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
