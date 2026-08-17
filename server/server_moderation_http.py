import base64
import hashlib
import hmac
import json
import secrets
import time
import uuid
from collections import defaultdict, deque
from pathlib import Path

try:
    from aiohttp import web
except ModuleNotFoundError:
    web = None

try:
    from server.config import (
        MODERATION_ADMIN_ID,
        MODERATION_ADMIN_PASSWORD_HASH,
        MODERATION_HTTP_HOST,
        MODERATION_HTTP_PORT,
        MODERATION_SESSION_SECRET,
    )
except ModuleNotFoundError:
    from config import (
        MODERATION_ADMIN_ID,
        MODERATION_ADMIN_PASSWORD_HASH,
        MODERATION_HTTP_HOST,
        MODERATION_HTTP_PORT,
        MODERATION_SESSION_SECRET,
    )


STATIC_ROOT = Path(__file__).resolve().parent / "static" / "moderation"
COOKIE_NAME = "mesh_moderation_session"
SESSION_SECONDS = 8 * 60 * 60
VALID_ACTIONS = {"keep", "needs_review"}


class ModerationHttpServer:
    def __init__(self, relay):
        self.relay = relay
        self.runner = None
        self.site = None
        self._login_attempts = defaultdict(deque)

    @property
    def enabled(self):
        return bool(MODERATION_ADMIN_PASSWORD_HASH and MODERATION_SESSION_SECRET)

    async def start(self):
        if not self.enabled:
            return False
        if web is None:
            raise RuntimeError("aiohttp is required for moderation admin")
        app = web.Application(client_max_size=32 * 1024)
        app.router.add_get("/admin/moderation", self._page)
        app.router.add_get("/admin/moderation/", self._page)
        app.router.add_get("/admin/moderation/styles.css", self._styles)
        app.router.add_get("/admin/moderation/app.js", self._script)
        app.router.add_post("/admin/moderation/api/login", self._login)
        app.router.add_post("/admin/moderation/api/logout", self._logout)
        app.router.add_get("/admin/moderation/api/session", self._session)
        app.router.add_get("/admin/moderation/api/reports", self._reports)
        app.router.add_post(
            "/admin/moderation/api/reports/{report_id}/decision",
            self._decision,
        )
        self.runner = web.AppRunner(app, access_log=None)
        await self.runner.setup()
        self.site = web.TCPSite(
            self.runner, MODERATION_HTTP_HOST, MODERATION_HTTP_PORT
        )
        await self.site.start()
        return True

    async def close(self):
        if self.runner is not None:
            await self.runner.cleanup()
            self.runner = None
            self.site = None

    async def _page(self, request):
        return self._static("index.html", "text/html", "no-store")

    async def _styles(self, request):
        return self._static("styles.css", "text/css", "public, max-age=3600")

    async def _script(self, request):
        return self._static("app.js", "application/javascript", "no-store")

    async def _login(self, request):
        ip = request.remote or "unknown"
        now = time.time()
        attempts = self._login_attempts[ip]
        while attempts and attempts[0] < now - 600:
            attempts.popleft()
        if len(attempts) >= 8:
            return self._json({"ok": False, "error": "too_many_attempts"}, 429)
        payload = await request.json()
        if not self._verify_password(str(payload.get("password") or "")):
            attempts.append(now)
            return self._json({"ok": False, "error": "invalid_credentials"}, 401)
        attempts.clear()
        csrf = secrets.token_urlsafe(24)
        token = self._session_token(MODERATION_ADMIN_ID, csrf, int(now))
        response = self._json({"ok": True, "csrf": csrf})
        response.set_cookie(
            COOKIE_NAME, token, max_age=SESSION_SECONDS, httponly=True,
            secure=True, samesite="Strict", path="/admin/moderation",
        )
        return response

    async def _logout(self, request):
        session = self._authenticated(request, csrf=True)
        if session is None:
            return self._json({"ok": False, "error": "unauthorized"}, 401)
        response = self._json({"ok": True})
        response.del_cookie(COOKIE_NAME, path="/admin/moderation")
        return response

    async def _session(self, request):
        session = self._authenticated(request)
        if session is None:
            return self._json({"ok": False}, 401)
        return self._json({"ok": True, "admin_id": session[0], "csrf": session[1]})

    async def _reports(self, request):
        if self._authenticated(request) is None:
            return self._json({"ok": False, "error": "unauthorized"}, 401)
        status = request.query.get("status", "new")
        with self.relay.unit_of_work_factory() as unit_of_work:
            reports = unit_of_work.moderation.list_reports(status=status, limit=100)
            for report in reports:
                report["actions"] = unit_of_work.moderation.actions_for_report(
                    report["report_id"]
                )
        return self._json({"ok": True, "reports": reports})

    async def _decision(self, request):
        session = self._authenticated(request, csrf=True)
        if session is None:
            return self._json({"ok": False, "error": "unauthorized"}, 401)
        payload = await request.json()
        action = str(payload.get("action") or "").strip().lower()
        if action not in VALID_ACTIONS:
            return self._json({"ok": False, "error": "invalid_action"}, 400)
        with self.relay.unit_of_work_factory(write=True) as unit_of_work:
            changed = unit_of_work.moderation.record_decision(
                request.match_info["report_id"], str(uuid.uuid4()), session[0],
                action, str(payload.get("note") or "")[:2000],
            )
        if not changed:
            return self._json({"ok": False, "error": "report_not_found"}, 404)
        return self._json({"ok": True})

    def _authenticated(self, request, csrf=False):
        token = request.cookies.get(COOKIE_NAME, "")
        parts = token.split(".")
        if len(parts) != 2:
            return None
        encoded, supplied = parts
        expected = hmac.new(
            MODERATION_SESSION_SECRET.encode(), encoded.encode(), hashlib.sha256
        ).hexdigest()
        if not hmac.compare_digest(supplied, expected):
            return None
        try:
            admin_id, issued, csrf_token = json.loads(
                self._b64decode(encoded).decode("utf-8")
            )
        except (ValueError, TypeError, json.JSONDecodeError):
            return None
        if time.time() - int(issued) > SESSION_SECONDS:
            return None
        if csrf and not hmac.compare_digest(
            request.headers.get("X-CSRF-Token", ""), csrf_token
        ):
            return None
        return admin_id, csrf_token

    def _session_token(self, admin_id, csrf, issued):
        encoded = self._b64encode(
            json.dumps([admin_id, issued, csrf], separators=(",", ":")).encode()
        )
        signature = hmac.new(
            MODERATION_SESSION_SECRET.encode(), encoded.encode(), hashlib.sha256
        ).hexdigest()
        return f"{encoded}.{signature}"

    @staticmethod
    def _verify_password(password):
        try:
            scheme, salt_value, digest_value = MODERATION_ADMIN_PASSWORD_HASH.split("$", 2)
            if scheme != "scrypt":
                return False
            salt = base64.urlsafe_b64decode(salt_value.encode())
            expected = base64.urlsafe_b64decode(digest_value.encode())
            actual = hashlib.scrypt(password.encode(), salt=salt, n=16384, r=8, p=1)
            return hmac.compare_digest(actual, expected)
        except (ValueError, TypeError):
            return False

    @staticmethod
    def _b64encode(value):
        return base64.urlsafe_b64encode(value).decode().rstrip("=")

    @staticmethod
    def _b64decode(value):
        return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))

    def _static(self, name, content_type, cache_control):
        response = web.FileResponse(STATIC_ROOT / name)
        response.content_type = content_type
        response.headers["Cache-Control"] = cache_control
        return self._secure(response)

    def _json(self, payload, status=200):
        return self._secure(web.json_response(payload, status=status))

    @staticmethod
    def _secure(response):
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; style-src 'self'; script-src 'self'; "
            "img-src 'self' data:; frame-ancestors 'none'"
        )
        return response
