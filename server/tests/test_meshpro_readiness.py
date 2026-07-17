import tempfile
import unittest
from pathlib import Path

from server import config
from server.ops.check_meshpro_readiness import collect_readiness


class MeshProReadinessTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.values = {
            name: getattr(config, name)
            for name in (
                "YOOKASSA_SHOP_ID",
                "YOOKASSA_SECRET_KEY",
                "YOOKASSA_WEBHOOK_SECRET",
                "LAVA_API_URL",
                "LAVA_API_KEY",
                "LAVA_WEBHOOK_KEY",
                "LAVA_PRODUCT_ID",
                "LAVA_OFFER_ID",
                "SBER_PAYMENT_URL",
                "SUBSCRIPTION_CHECKOUT_URL",
                "BOOSTY_TELEGRAM_BOT_TOKEN",
                "BOOSTY_TELEGRAM_GROUP_ID",
                "BOOSTY_TELEGRAM_OWNER_ID",
                "BOOSTY_ACTIVATION_SECRET",
                "BOOSTY_ACTIVATION_URL",
                "WIREGUARD_ENABLED",
                "WIREGUARD_ENDPOINT",
                "WIREGUARD_SERVER_PUBLIC_KEY",
                "WIREGUARD_NETWORK",
                "WIREGUARD_SERVER_ADDRESS",
                "WIREGUARD_PEER_DIR",
            )
        }
        config.YOOKASSA_SHOP_ID = "YOUR_TEST_SHOP_ID"
        config.YOOKASSA_SECRET_KEY = "YOUR_TEST_SECRET_KEY"
        config.YOOKASSA_WEBHOOK_SECRET = "GENERATE_WITH_OPENSSL_RAND_HEX_32"
        config.LAVA_API_URL = "https://gate.lava.top"
        config.LAVA_API_KEY = ""
        config.LAVA_WEBHOOK_KEY = ""
        config.LAVA_PRODUCT_ID = ""
        config.LAVA_OFFER_ID = ""
        config.SBER_PAYMENT_URL = "https://pay.example/sber"
        config.SUBSCRIPTION_CHECKOUT_URL = "https://mesh.example/meshpro/"
        config.BOOSTY_TELEGRAM_BOT_TOKEN = ""
        config.BOOSTY_TELEGRAM_GROUP_ID = ""
        config.BOOSTY_TELEGRAM_OWNER_ID = ""
        config.BOOSTY_ACTIVATION_SECRET = ""
        config.BOOSTY_ACTIVATION_URL = (
            "https://mesh.example/meshpro/activate"
        )
        config.WIREGUARD_ENABLED = True
        config.WIREGUARD_ENDPOINT = "vpn.example:51820"
        config.WIREGUARD_SERVER_PUBLIC_KEY = (
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        )
        config.WIREGUARD_NETWORK = "10.77.0.0/24"
        config.WIREGUARD_SERVER_ADDRESS = "10.77.0.1"
        config.WIREGUARD_PEER_DIR = Path(self.temp_dir.name) / "peers"

    def tearDown(self):
        for name, value in self.values.items():
            setattr(config, name, value)
        self.temp_dir.cleanup()

    def test_manual_sber_mode_ignores_yookassa_placeholders(self):
        report = collect_readiness()
        self.assertTrue(report["ok"], report["errors"])
        self.assertEqual(["sber_manual"], report["providers"])

    def test_placeholder_sber_link_is_not_accepted(self):
        config.SBER_PAYMENT_URL = (
            "https://messenger.online.sberbank.ru/sl/PASTE_LINK"
        )
        report = collect_readiness()
        self.assertFalse(report["ok"])
        self.assertIn(
            "MESH_SBER_PAYMENT_URL must be a non-placeholder HTTPS URL",
            report["errors"],
        )

    def test_complete_lava_mode_is_ready(self):
        config.SBER_PAYMENT_URL = ""
        config.LAVA_API_KEY = "lava-api-key"
        config.LAVA_WEBHOOK_KEY = "a" * 32
        config.LAVA_PRODUCT_ID = "product-id"
        config.LAVA_OFFER_ID = "offer-id"
        report = collect_readiness()
        self.assertTrue(report["ok"], report["errors"])
        self.assertEqual(["lava"], report["providers"])

    def test_complete_boosty_mode_is_ready(self):
        config.SBER_PAYMENT_URL = ""
        config.BOOSTY_TELEGRAM_BOT_TOKEN = "123456789:test-token"
        config.BOOSTY_TELEGRAM_GROUP_ID = "-1001234567890"
        config.BOOSTY_TELEGRAM_OWNER_ID = "987654321"
        config.BOOSTY_ACTIVATION_SECRET = "b" * 64
        report = collect_readiness()
        self.assertTrue(report["ok"], report["errors"])
        self.assertEqual(["boosty_telegram"], report["providers"])


if __name__ == "__main__":
    unittest.main()
