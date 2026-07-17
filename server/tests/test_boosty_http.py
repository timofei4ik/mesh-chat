import tempfile
import unittest
from pathlib import Path

try:
    import aiohttp
except ModuleNotFoundError:
    aiohttp = None

from server import (
    server_auth,
    server_billing_http,
    server_boosty,
    server_storage,
    server_subscription,
)


class BoostyHttpRelay(
    server_storage.ServerStorageMixin,
    server_auth.ServerAuthMixin,
    server_boosty.ServerBoostyMixin,
    server_subscription.ServerSubscriptionMixin,
):
    manual_billing_configured = False
    billing_configured = False
    subscription_checkout_ready = False
    yookassa_billing_configured = False
    lava_billing_configured = False

    def __init__(self):
        self.db = self.open_db()
        self._boosty_bot_username = "meshpro_test_bot"

    async def _boosty_user_is_member(self, telegram_user_id):
        return True


@unittest.skipIf(
    aiohttp is None or server_billing_http.web is None,
    "billing HTTP dependencies are not installed",
)
class BoostyHttpTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.previous = {
            "db_path": server_storage.DB_PATH,
            "secret": server_boosty.BOOSTY_ACTIVATION_SECRET,
            "token": server_boosty.BOOSTY_TELEGRAM_BOT_TOKEN,
            "group": server_boosty.BOOSTY_TELEGRAM_GROUP_ID,
            "url": server_boosty.BOOSTY_ACTIVATION_URL,
            "host": server_billing_http.BILLING_HOST,
            "port": server_billing_http.BILLING_PORT,
        }
        server_storage.DB_PATH = Path(self.temp_dir.name) / "server.db"
        server_boosty.BOOSTY_ACTIVATION_SECRET = "h" * 48
        server_boosty.BOOSTY_TELEGRAM_BOT_TOKEN = "test-token"
        server_boosty.BOOSTY_TELEGRAM_GROUP_ID = "-1001234567890"
        server_boosty.BOOSTY_ACTIVATION_URL = (
            "https://mesh.example/meshpro/activate"
        )
        server_billing_http.BILLING_HOST = "127.0.0.1"
        server_billing_http.BILLING_PORT = 0
        self.relay = BoostyHttpRelay()
        self.relay.authenticate_account(
            "subscriber",
            "correct-password",
            "node-a",
            "Subscriber",
        )
        self.http = server_billing_http.BillingHttpServer(self.relay)
        self.assertTrue(await self.http.start())
        socket = self.http.site._server.sockets[0]
        self.base_url = f"http://127.0.0.1:{socket.getsockname()[1]}"
        self.session = aiohttp.ClientSession()

    async def asyncTearDown(self):
        await self.session.close()
        await self.http.close()
        self.relay.db.close()
        server_storage.DB_PATH = self.previous["db_path"]
        server_boosty.BOOSTY_ACTIVATION_SECRET = self.previous["secret"]
        server_boosty.BOOSTY_TELEGRAM_BOT_TOKEN = self.previous["token"]
        server_boosty.BOOSTY_TELEGRAM_GROUP_ID = self.previous["group"]
        server_boosty.BOOSTY_ACTIVATION_URL = self.previous["url"]
        server_billing_http.BILLING_HOST = self.previous["host"]
        server_billing_http.BILLING_PORT = self.previous["port"]
        self.temp_dir.cleanup()

    async def test_activation_page_info_and_submit(self):
        async with self.session.get(
            f"{self.base_url}/meshpro/activate"
        ) as response:
            page = await response.text()
            self.assertEqual(200, response.status)
            self.assertIn('id="activation-form"', page)
            self.assertEqual("no-store", response.headers["Cache-Control"])

        async with self.session.get(
            f"{self.base_url}/billing/boosty/info"
        ) as response:
            info = await response.json()
            self.assertEqual(200, response.status)
            self.assertTrue(info["configured"])
            self.assertEqual("meshpro_test_bot", info["bot_username"])

        code = self.relay.create_boosty_activation_code(501, "subscriber_tg")
        async with self.session.post(
            f"{self.base_url}/billing/boosty/activate",
            json={
                "login": "subscriber",
                "password": "correct-password",
                "code": code,
            },
        ) as response:
            result = await response.json()
            self.assertEqual(200, response.status)
            self.assertTrue(result["ok"])
            self.assertTrue(result["subscription"]["active"])

        dump = "\n".join(self.relay.db.iterdump())
        self.assertNotIn("correct-password", dump)
        self.assertNotIn(code, dump)


if __name__ == "__main__":
    unittest.main()
