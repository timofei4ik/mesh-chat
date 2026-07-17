import tempfile
import unittest
import copy
from pathlib import Path

try:
    import aiohttp
except ModuleNotFoundError:
    aiohttp = None

from server import (
    server_billing,
    server_billing_http,
    server_storage,
    server_subscription,
)


class BillingHttpRelay(
    server_storage.ServerStorageMixin,
    server_billing.ServerBillingMixin,
    server_subscription.ServerSubscriptionMixin,
):
    def __init__(self):
        self.lava_invoices = {}
        self.db = self.open_db()

    async def _lava_request(self, method, path, payload=None):
        if method == "POST" and path == "/api/v3/invoice":
            invoice_id = "lava-http-invoice"
            self.lava_invoices[invoice_id] = {
                "id": invoice_id,
                "type": "SUBSCRIPTION_FIRST_INVOICE",
                "status": "NEW",
                "receipt": {"amount": "199.00", "currency": "RUB"},
                "buyer": {"email": payload["email"]},
                "product": {
                    "id": server_billing.LAVA_PRODUCT_ID,
                    "offer": {"id": server_billing.LAVA_OFFER_ID},
                },
                "clientUtm": copy.deepcopy(payload["clientUtm"]),
            }
            return {
                "id": invoice_id,
                "status": "NEW",
                "amountTotal": {"amount": "199.00", "currency": "RUB"},
                "paymentUrl": "https://pay.lava.test/lava-http-invoice",
            }
        if method == "GET" and path == "/api/v2/invoices/lava-http-invoice":
            return copy.deepcopy(self.lava_invoices["lava-http-invoice"])
        raise AssertionError((method, path, payload))


@unittest.skipIf(
    (
        aiohttp is None
        or server_billing_http.web is None
    ),
    "billing HTTP dependencies are not installed",
)
class BillingHttpTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.previous_values = {
            "db_path": server_storage.DB_PATH,
            "shop_id": server_billing.YOOKASSA_SHOP_ID,
            "secret": server_billing.YOOKASSA_SECRET_KEY,
            "webhook_secret": server_billing.YOOKASSA_WEBHOOK_SECRET,
            "lava_api_key": server_billing.LAVA_API_KEY,
            "lava_webhook_key": server_billing.LAVA_WEBHOOK_KEY,
            "lava_product_id": server_billing.LAVA_PRODUCT_ID,
            "lava_offer_id": server_billing.LAVA_OFFER_ID,
            "http_lava_webhook_key": server_billing_http.LAVA_WEBHOOK_KEY,
            "sber_url": server_billing.SBER_PAYMENT_URL,
            "checkout_url": server_billing.SUBSCRIPTION_CHECKOUT_URL,
            "wireguard_enabled": server_billing.WIREGUARD_ENABLED,
            "wireguard_endpoint": server_billing.WIREGUARD_ENDPOINT,
            "billing_host": server_billing_http.BILLING_HOST,
            "billing_port": server_billing_http.BILLING_PORT,
        }
        server_storage.DB_PATH = Path(self.temp_dir.name) / "server.db"
        server_billing.YOOKASSA_SHOP_ID = ""
        server_billing.YOOKASSA_SECRET_KEY = ""
        server_billing.YOOKASSA_WEBHOOK_SECRET = ""
        server_billing.LAVA_API_KEY = ""
        server_billing.LAVA_WEBHOOK_KEY = ""
        server_billing.LAVA_PRODUCT_ID = ""
        server_billing.LAVA_OFFER_ID = ""
        server_billing_http.LAVA_WEBHOOK_KEY = ""
        server_billing.SBER_PAYMENT_URL = "https://pay.example/sber"
        server_billing.SUBSCRIPTION_CHECKOUT_URL = (
            "https://mesh.example/meshpro/"
        )
        server_billing.WIREGUARD_ENABLED = True
        server_billing.WIREGUARD_ENDPOINT = "vpn.test:51820"
        server_billing_http.BILLING_HOST = "127.0.0.1"
        server_billing_http.BILLING_PORT = 0

        self.relay = BillingHttpRelay()
        self.relay.db.execute(
            """
            INSERT INTO accounts(
                login,
                password_salt,
                password_hash,
                display_name
            )
            VALUES('subscriber', 'salt', 'hash', 'Subscriber')
            """
        )
        self.relay.db.commit()
        self.http = server_billing_http.BillingHttpServer(self.relay)
        self.assertTrue(await self.http.start())
        socket = self.http.site._server.sockets[0]
        self.base_url = f"http://127.0.0.1:{socket.getsockname()[1]}"
        self.session = aiohttp.ClientSession()

    async def asyncTearDown(self):
        await self.session.close()
        await self.http.close()
        self.relay.db.close()
        server_storage.DB_PATH = self.previous_values["db_path"]
        server_billing.YOOKASSA_SHOP_ID = self.previous_values["shop_id"]
        server_billing.YOOKASSA_SECRET_KEY = self.previous_values["secret"]
        server_billing.YOOKASSA_WEBHOOK_SECRET = self.previous_values[
            "webhook_secret"
        ]
        server_billing.LAVA_API_KEY = self.previous_values["lava_api_key"]
        server_billing.LAVA_WEBHOOK_KEY = self.previous_values[
            "lava_webhook_key"
        ]
        server_billing.LAVA_PRODUCT_ID = self.previous_values[
            "lava_product_id"
        ]
        server_billing.LAVA_OFFER_ID = self.previous_values["lava_offer_id"]
        server_billing_http.LAVA_WEBHOOK_KEY = self.previous_values[
            "http_lava_webhook_key"
        ]
        server_billing.SBER_PAYMENT_URL = self.previous_values["sber_url"]
        server_billing.SUBSCRIPTION_CHECKOUT_URL = self.previous_values[
            "checkout_url"
        ]
        server_billing.WIREGUARD_ENABLED = self.previous_values[
            "wireguard_enabled"
        ]
        server_billing.WIREGUARD_ENDPOINT = self.previous_values[
            "wireguard_endpoint"
        ]
        server_billing_http.BILLING_HOST = self.previous_values[
            "billing_host"
        ]
        server_billing_http.BILLING_PORT = self.previous_values[
            "billing_port"
        ]
        self.temp_dir.cleanup()

    @unittest.skipIf(
        server_billing_http.qrcode is None,
        "QR dependency is not installed",
    )
    async def test_manual_payment_page_and_approval_flow(self):
        async with self.session.get(f"{self.base_url}/meshpro/") as response:
            page = await response.text()
            self.assertEqual(200, response.status)
            self.assertIn('id="period-days">30</span> дней', page)
            self.assertEqual("no-store", response.headers["Cache-Control"])
            self.assertEqual("DENY", response.headers["X-Frame-Options"])

        async with self.session.get(
            f"{self.base_url}/billing/manual/qr.svg"
        ) as response:
            qr = await response.text()
            self.assertEqual(200, response.status)
            self.assertIn("svg", response.content_type)
            self.assertIn("<svg", qr)

        async with self.session.post(
            f"{self.base_url}/billing/manual/orders",
            json={"login": "subscriber"},
        ) as response:
            payload = await response.json()
            self.assertEqual(200, response.status)
        order = payload["order"]
        self.assertEqual("subscriber", order["login"])
        self.assertEqual("pending", order["status"])
        self.assertFalse(
            self.relay.subscription_status("subscriber")["active"]
        )

        async with self.session.post(
            (
                f"{self.base_url}/billing/manual/orders/"
                f"{order['order_id']}/submitted"
            ),
            json={"checkout_key": order["checkout_key"]},
        ) as response:
            submitted = await response.json()
            self.assertEqual(200, response.status)
            self.assertEqual("customer_reported", submitted["status"])
        self.assertFalse(
            self.relay.subscription_status("subscriber")["active"]
        )

        self.relay.approve_manual_subscription_order(order["reference"])
        async with self.session.get(
            (
                f"{self.base_url}/billing/manual/orders/"
                f"{order['order_id']}?key={order['checkout_key']}"
            )
        ) as response:
            approved = await response.json()
            self.assertEqual(200, response.status)
            self.assertEqual("succeeded", approved["status"])
        self.assertTrue(
            self.relay.subscription_status("subscriber")["active"]
        )

    async def test_lava_checkout_and_authenticated_webhook(self):
        server_billing.LAVA_API_KEY = "lava-api-key"
        server_billing.LAVA_WEBHOOK_KEY = "lava-webhook-key"
        server_billing.LAVA_PRODUCT_ID = "product-meshpro"
        server_billing.LAVA_OFFER_ID = "offer-monthly"
        server_billing_http.LAVA_WEBHOOK_KEY = "lava-webhook-key"

        async with self.session.get(
            f"{self.base_url}/billing/offer"
        ) as response:
            offer = await response.json()
            self.assertEqual(200, response.status)
            self.assertEqual("lava", offer["provider"])
            self.assertTrue(offer["email_required"])

        async with self.session.post(
            f"{self.base_url}/billing/checkout",
            json={
                "login": "subscriber",
                "email": "buyer@example.com",
            },
        ) as response:
            checkout_payload = await response.json()
            self.assertEqual(200, response.status)
        self.assertEqual(
            "https://pay.lava.test/lava-http-invoice",
            checkout_payload["checkout"]["confirmation_url"],
        )

        notification = {
            "eventType": "payment.success",
            "contractId": "lava-http-invoice",
            "product": {"id": "product-meshpro"},
            "buyer": {"email": "buyer@example.com"},
        }
        async with self.session.post(
            f"{self.base_url}/billing/lava/webhook",
            json=notification,
        ) as response:
            self.assertEqual(401, response.status)

        self.relay.lava_invoices["lava-http-invoice"][
            "status"
        ] = "COMPLETED"
        async with self.session.post(
            f"{self.base_url}/billing/lava/webhook",
            json=notification,
            headers={"X-Api-Key": "lava-webhook-key"},
        ) as response:
            result = await response.json()
            self.assertEqual(200, response.status)
            self.assertTrue(result["result"]["subscription"]["active"])


if __name__ == "__main__":
    unittest.main()
