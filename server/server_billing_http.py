import hmac
import io
import time
import uuid
from collections import defaultdict, deque
from pathlib import Path

try:
    from aiohttp import web
except ModuleNotFoundError:  # Installed from server/requirements.txt in production.
    web = None

try:
    import qrcode
    from qrcode.image.svg import SvgPathImage
except ModuleNotFoundError:  # Installed from server/requirements.txt in production.
    qrcode = None
    SvgPathImage = None

try:
    from server.config import (
        BILLING_HOST,
        BILLING_PORT,
        LAVA_WEBHOOK_KEY,
        YOOKASSA_WEBHOOK_SECRET,
    )
    from server.server_billing import BillingError
    from server.server_boosty import BoostyActivationError
except ModuleNotFoundError:
    from config import (
        BILLING_HOST,
        BILLING_PORT,
        LAVA_WEBHOOK_KEY,
        YOOKASSA_WEBHOOK_SECRET,
    )
    from server_billing import BillingError
    from server_boosty import BoostyActivationError


MAX_NOTIFICATION_BYTES = 64 * 1024
MAX_ORDER_BYTES = 4 * 1024
ORDER_RATE_LIMIT = 10
ORDER_RATE_WINDOW_SECONDS = 10 * 60
STATIC_ROOT = Path(__file__).resolve().parent / "static" / "meshpro"
PROJECT_ROOT = Path(__file__).resolve().parents[1]


class BillingHttpServer:
    def __init__(self, relay):
        self.relay = relay
        self.runner = None
        self.site = None
        self._order_attempts = defaultdict(deque)

    @property
    def enabled(self):
        return bool(
            self.relay.manual_billing_configured
            or self.relay.billing_configured
            or getattr(self.relay, "boosty_activation_configured", False)
        )

    async def start(self):
        if not self.enabled:
            return False
        if web is None:
            raise RuntimeError("aiohttp is required for the billing server")
        app = web.Application(client_max_size=MAX_NOTIFICATION_BYTES)
        app.router.add_get("/billing/health", self._health)
        app.router.add_get(
            "/billing/payment-complete",
            self._payment_complete,
        )
        app.router.add_post(
            "/billing/yookassa/{secret}",
            self._yookassa_notification,
        )
        app.router.add_post(
            "/billing/lava/webhook",
            self._lava_notification,
        )
        app.router.add_get("/billing/offer", self._billing_offer)
        app.router.add_post("/billing/checkout", self._billing_checkout)
        app.router.add_get("/meshpro", self._meshpro_redirect)
        app.router.add_get("/meshpro/", self._meshpro_page)
        app.router.add_get("/meshpro/styles.css", self._meshpro_styles)
        app.router.add_get("/meshpro/app.js", self._meshpro_script)
        app.router.add_get("/meshpro/activate", self._boosty_activate_page)
        app.router.add_get("/meshpro/activate/", self._boosty_activate_page)
        app.router.add_get(
            "/meshpro/activate.js",
            self._boosty_activate_script,
        )
        app.router.add_get("/meshpro/logo.png", self._meshpro_logo)
        app.router.add_get("/billing/boosty/info", self._boosty_info)
        app.router.add_post(
            "/billing/boosty/activate",
            self._boosty_activate,
        )
        app.router.add_get("/billing/manual/qr.svg", self._manual_qr)
        app.router.add_post("/billing/manual/orders", self._manual_order)
        app.router.add_get(
            "/billing/manual/orders/{order_id}",
            self._manual_order_status,
        )
        app.router.add_post(
            "/billing/manual/orders/{order_id}/submitted",
            self._manual_order_submitted,
        )
        self.runner = web.AppRunner(app, access_log=None)
        await self.runner.setup()
        self.site = web.TCPSite(self.runner, BILLING_HOST, BILLING_PORT)
        await self.site.start()
        return True

    async def close(self):
        if self.runner is not None:
            await self.runner.cleanup()
            self.runner = None
            self.site = None

    async def _health(self, request):
        checkout_ready = bool(self.relay.subscription_checkout_ready)
        providers = []
        if self.relay.manual_billing_configured:
            providers.append("sber_manual")
        if self.relay.yookassa_billing_configured:
            providers.append("yookassa")
        if self.relay.lava_billing_configured:
            providers.insert(0, "lava")
        boosty_ready = bool(
            getattr(self.relay, "boosty_activation_configured", False)
        )
        if boosty_ready:
            providers.append("boosty_telegram")
        return self._json_response(
            {
                "ok": checkout_ready or boosty_ready,
                "providers": providers,
                "product": "meshpro",
                "checkout_ready": checkout_ready,
                "boosty_activation_ready": boosty_ready,
            },
            status=200 if checkout_ready or boosty_ready else 503,
        )

    async def _payment_complete(self, request):
        response = web.Response(
            text=(
                "<!doctype html><html lang='ru'><meta charset='utf-8'>"
                "<meta name='viewport' content='width=device-width,initial-scale=1'>"
                "<title>MeshPro</title>"
                "<body style='background:#07111e;color:#eef6ff;font:16px system-ui;"
                "display:grid;place-items:center;min-height:100vh;margin:0'>"
                "<main style='text-align:center;padding:28px'>"
                "<h1>Платёж отправлен</h1>"
                "<p>Вернитесь в приложение и обновите статус MeshPro.</p>"
                "</main></body></html>"
            ),
            content_type="text/html",
            charset="utf-8",
        )
        return self._secure_response(response)

    async def _yookassa_notification(self, request):
        supplied_secret = request.match_info.get("secret", "")
        if not hmac.compare_digest(supplied_secret, YOOKASSA_WEBHOOK_SECRET):
            raise web.HTTPNotFound()
        try:
            notification = await request.json()
            result = await self.relay.process_yookassa_notification(notification)
        except (BillingError, ValueError) as error:
            print(f"Rejected YooKassa notification: {error}")
            return self._json_response(
                {"ok": False, "error": str(error)},
                status=503,
            )
        except Exception as error:
            print(f"YooKassa notification failed: {error}")
            return self._json_response(
                {"ok": False, "error": "notification processing failed"},
                status=503,
            )
        return self._json_response({"ok": True, "result": result})

    async def _lava_notification(self, request):
        supplied_key = request.headers.get("X-Api-Key", "").strip()
        if not LAVA_WEBHOOK_KEY or not hmac.compare_digest(
            supplied_key,
            LAVA_WEBHOOK_KEY,
        ):
            return self._json_response(
                {"ok": False, "error": "unauthorized"},
                status=401,
            )
        try:
            notification = await request.json()
            result = await self.relay.process_lava_notification(notification)
        except (BillingError, ValueError) as error:
            print(f"Rejected Lava notification: {error}")
            return self._json_response(
                {"ok": False, "error": str(error)},
                status=503,
            )
        except Exception as error:
            print(f"Lava notification failed: {error}")
            return self._json_response(
                {"ok": False, "error": "notification processing failed"},
                status=503,
            )
        return self._json_response({"ok": True, "result": result})

    async def _billing_offer(self, request):
        offer = self.relay.subscription_offer("meshpro")
        checkout_available = bool(offer.get("checkout_available"))
        return self._json_response(
            {
                "ok": checkout_available,
                "provider": self.relay.active_billing_provider,
                "product": "meshpro",
                "price_value": offer.get("price_value"),
                "currency": offer.get("currency"),
                "period_days": offer.get("period_days"),
                "email_required": self.relay.lava_billing_configured,
            },
            status=200 if checkout_available else 503,
        )

    async def _billing_checkout(self, request):
        if not self._order_attempt_allowed(request):
            return self._json_response(
                {"ok": False, "error": "too_many_attempts"},
                status=429,
            )
        if request.content_length and request.content_length > MAX_ORDER_BYTES:
            return self._json_response(
                {"ok": False, "error": "request_too_large"},
                status=413,
            )
        try:
            payload = await request.json()
            login = str(payload.get("login") or "").strip()
            if self.relay.active_billing_provider == "sber_manual":
                checkout = self.relay.create_manual_subscription_order(login)
            else:
                checkout = await self.relay.create_subscription_checkout(
                    login,
                    "web-checkout",
                    str(payload.get("client_request_id") or uuid.uuid4()),
                    "meshpro",
                    "monthly",
                    buyer_email=payload.get("email"),
                )
        except BillingError as error:
            status = 404 if str(error) == "account does not exist" else 400
            return self._json_response(
                {"ok": False, "error": str(error)},
                status=status,
            )
        except (ValueError, TypeError):
            return self._json_response(
                {"ok": False, "error": "invalid_request"},
                status=400,
            )
        return self._json_response({"ok": True, "checkout": checkout})

    async def _meshpro_redirect(self, request):
        raise web.HTTPPermanentRedirect("/meshpro/")

    async def _meshpro_page(self, request):
        return self._static_response(
            STATIC_ROOT / "index.html",
            "text/html",
            cache_control="no-store",
        )

    async def _meshpro_styles(self, request):
        return self._static_response(
            STATIC_ROOT / "styles.css",
            "text/css",
        )

    async def _meshpro_script(self, request):
        return self._static_response(
            STATIC_ROOT / "app.js",
            "application/javascript",
        )

    async def _boosty_activate_page(self, request):
        return self._static_response(
            STATIC_ROOT / "activate.html",
            "text/html",
            cache_control="no-store",
        )

    async def _boosty_activate_script(self, request):
        return self._static_response(
            STATIC_ROOT / "activate.js",
            "application/javascript",
            cache_control="no-store",
        )

    async def _boosty_info(self, request):
        if not hasattr(self.relay, "boosty_public_info"):
            return self._json_response(
                {"ok": False, "configured": False},
                status=503,
            )
        info = self.relay.boosty_public_info()
        return self._json_response(
            {"ok": bool(info.get("configured")), **info},
            status=200 if info.get("configured") else 503,
        )

    async def _boosty_activate(self, request):
        if not self._order_attempt_allowed(request):
            return self._json_response(
                {"ok": False, "error": "too_many_attempts"},
                status=429,
            )
        if request.content_length and request.content_length > MAX_ORDER_BYTES:
            return self._json_response(
                {"ok": False, "error": "request_too_large"},
                status=413,
            )
        try:
            payload = await request.json()
            result = await self.relay.activate_boosty_subscription(
                str(payload.get("login") or ""),
                str(payload.get("password") or ""),
                str(payload.get("code") or ""),
            )
        except BoostyActivationError as error:
            error_code = str(error)
            status = {
                "invalid_credentials": 401,
                "boosty_not_configured": 503,
            }.get(error_code, 400)
            return self._json_response(
                {"ok": False, "error": error_code},
                status=status,
            )
        except (ValueError, TypeError):
            return self._json_response(
                {"ok": False, "error": "invalid_request"},
                status=400,
            )
        return self._json_response({"ok": True, **result})

    async def _meshpro_logo(self, request):
        return self._static_response(
            STATIC_ROOT / "logo.png",
            "image/png",
        )

    async def _manual_qr(self, request):
        if not self.relay.manual_billing_configured:
            return self._json_response(
                {"ok": False, "error": "payment_not_configured"},
                status=503,
            )
        if qrcode is None or SvgPathImage is None:
            return self._json_response(
                {"ok": False, "error": "qr_backend_unavailable"},
                status=503,
            )
        payment_url = self.relay._validated_sber_payment_url()
        output = io.BytesIO()
        image = qrcode.make(
            payment_url,
            image_factory=SvgPathImage,
            box_size=10,
            border=3,
        )
        image.save(output)
        response = web.Response(
            body=output.getvalue(),
            content_type="image/svg+xml",
        )
        return self._secure_response(response, cache_control="no-store")

    async def _manual_order(self, request):
        if not self.relay.manual_billing_configured:
            return self._json_response(
                {"ok": False, "error": "payment_not_configured"},
                status=503,
            )
        if not self._order_attempt_allowed(request):
            return self._json_response(
                {"ok": False, "error": "too_many_attempts"},
                status=429,
            )
        if request.content_length and request.content_length > MAX_ORDER_BYTES:
            return self._json_response(
                {"ok": False, "error": "request_too_large"},
                status=413,
            )
        try:
            payload = await request.json()
            login = str(payload.get("login") or "").strip()
            order = self.relay.create_manual_subscription_order(login)
        except BillingError as error:
            status = 404 if str(error) == "account does not exist" else 400
            return self._json_response(
                {"ok": False, "error": str(error)},
                status=status,
            )
        except (ValueError, TypeError):
            return self._json_response(
                {"ok": False, "error": "invalid_request"},
                status=400,
            )
        return self._json_response({"ok": True, "order": order})

    async def _manual_order_status(self, request):
        try:
            result = self.relay.manual_order_status(
                request.match_info.get("order_id"),
                request.query.get("key"),
            )
        except BillingError:
            return self._json_response(
                {"ok": False, "error": "order_not_found"},
                status=404,
            )
        return self._json_response({"ok": True, **result})

    async def _manual_order_submitted(self, request):
        try:
            payload = await request.json()
            result = self.relay.mark_manual_order_submitted(
                request.match_info.get("order_id"),
                payload.get("checkout_key"),
            )
        except BillingError:
            return self._json_response(
                {"ok": False, "error": "order_not_found"},
                status=404,
            )
        except (ValueError, TypeError):
            return self._json_response(
                {"ok": False, "error": "invalid_request"},
                status=400,
            )
        return self._json_response({"ok": True, **result})

    def _order_attempt_allowed(self, request):
        forwarded = request.headers.get("X-Real-IP", "").strip()
        peer = request.transport.get_extra_info("peername") if request.transport else None
        client_ip = forwarded or (str(peer[0]) if peer else "unknown")
        now = time.monotonic()
        attempts = self._order_attempts[client_ip]
        while attempts and now - attempts[0] > ORDER_RATE_WINDOW_SECONDS:
            attempts.popleft()
        if len(attempts) >= ORDER_RATE_LIMIT:
            return False
        attempts.append(now)
        return True

    def _static_response(
        self,
        path,
        content_type,
        cache_control="public, max-age=3600",
    ):
        if not path.is_file():
            raise web.HTTPNotFound()
        response = web.FileResponse(path)
        response.content_type = content_type
        if content_type.startswith("text/") or content_type in {
            "application/javascript",
            "application/json",
        }:
            response.charset = "utf-8"
        return self._secure_response(response, cache_control=cache_control)

    def _json_response(self, payload, status=200):
        return self._secure_response(
            web.json_response(payload, status=status),
            cache_control="no-store",
        )

    def _secure_response(self, response, cache_control="no-store"):
        response.headers["Cache-Control"] = cache_control
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Permissions-Policy"] = (
            "camera=(), microphone=(), geolocation=()"
        )
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; "
            "base-uri 'none'; "
            "frame-ancestors 'none'; "
            "img-src 'self' data:; "
            "style-src 'self'; "
            "script-src 'self'; "
            "connect-src 'self';"
        )
        return response
