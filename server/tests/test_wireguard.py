import tempfile
import unittest
from pathlib import Path

from server import server_storage, server_subscription, server_wireguard


class WireGuardRelay(
    server_storage.ServerStorageMixin,
    server_wireguard.ServerWireGuardMixin,
    server_subscription.ServerSubscriptionMixin,
):
    def __init__(self):
        self.applied = []
        self.removed = []
        self.key_counter = 0
        self.db = self.open_db()

    def _generate_wireguard_keys(self):
        self.key_counter += 1
        return (
            f"private-key-{self.key_counter}",
            f"public-key-{self.key_counter}",
        )

    def _apply_wireguard_peer(self, public_key, address):
        self.applied.append((public_key, address))

    def _remove_wireguard_peer(self, public_key):
        self.removed.append(public_key)


class WireGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.previous_values = {
            "DB_PATH": server_storage.DB_PATH,
            "WIREGUARD_ENABLED": server_wireguard.WIREGUARD_ENABLED,
            "WIREGUARD_ENDPOINT": server_wireguard.WIREGUARD_ENDPOINT,
            "WIREGUARD_NETWORK": server_wireguard.WIREGUARD_NETWORK,
            "WIREGUARD_SERVER_ADDRESS": server_wireguard.WIREGUARD_SERVER_ADDRESS,
            "WIREGUARD_SERVER_PUBLIC_KEY": server_wireguard.WIREGUARD_SERVER_PUBLIC_KEY,
            "WIREGUARD_PEER_DIR": server_wireguard.WIREGUARD_PEER_DIR,
        }
        server_storage.DB_PATH = Path(self.temp_dir.name) / "server.db"
        server_wireguard.WIREGUARD_ENABLED = True
        server_wireguard.WIREGUARD_ENDPOINT = "vpn.example.test:51820"
        server_wireguard.WIREGUARD_NETWORK = "10.77.0.0/29"
        server_wireguard.WIREGUARD_SERVER_ADDRESS = "10.77.0.1"
        server_wireguard.WIREGUARD_SERVER_PUBLIC_KEY = "server-public-key"
        server_wireguard.WIREGUARD_PEER_DIR = (
            Path(self.temp_dir.name) / "peers"
        )
        self.relay = WireGuardRelay()
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
        self.relay.db.execute(
            """
            INSERT INTO accounts(
                login,
                password_salt,
                password_hash,
                display_name
            )
            VALUES('second', 'salt', 'hash', 'Second')
            """
        )
        self.relay.db.commit()

    def tearDown(self):
        self.relay.db.close()
        server_storage.DB_PATH = self.previous_values["DB_PATH"]
        for key, value in self.previous_values.items():
            if key != "DB_PATH":
                setattr(server_wireguard, key, value)
        self.temp_dir.cleanup()

    def test_each_device_gets_a_distinct_peer_and_address(self):
        self.relay.grant_subscription("subscriber", days=30)
        first, _, first_reason = self.relay.vpn_config_for(
            "subscriber",
            "device-a",
        )
        second, _, second_reason = self.relay.vpn_config_for(
            "subscriber",
            "device-b",
        )
        self.assertEqual("ok", first_reason)
        self.assertEqual("ok", second_reason)
        self.assertIn("PrivateKey = private-key-1", first)
        self.assertIn("PrivateKey = private-key-2", second)
        addresses = {
            row[0]
            for row in self.relay.db.execute(
                "SELECT address FROM vpn_peers WHERE status='active'"
            ).fetchall()
        }
        self.assertEqual({"10.77.0.2", "10.77.0.3"}, addresses)

    def test_revoking_subscription_removes_all_device_peers(self):
        self.relay.grant_subscription("subscriber", days=30)
        self.relay.vpn_config_for("subscriber", "device-a")
        self.relay.vpn_config_for("subscriber", "device-b")
        paths = [
            Path(row[0])
            for row in self.relay.db.execute(
                "SELECT config_path FROM vpn_peers"
            ).fetchall()
        ]
        self.assertTrue(all(path.is_file() for path in paths))

        self.relay.revoke_subscription("subscriber")
        statuses = {
            row[0]
            for row in self.relay.db.execute(
                "SELECT status FROM vpn_peers"
            ).fetchall()
        }
        self.assertEqual({"revoked"}, statuses)
        self.assertEqual(
            {"public-key-1", "public-key-2"},
            set(self.relay.removed),
        )
        self.assertTrue(all(not path.exists() for path in paths))

    def test_revoked_address_can_be_reused_safely(self):
        self.relay.grant_subscription("subscriber", days=30)
        self.relay.vpn_config_for("subscriber", "device-a")
        self.relay.revoke_subscription("subscriber")

        self.relay.grant_subscription("second", days=30)
        config, _, reason = self.relay.vpn_config_for("second", "device-z")
        self.assertEqual("ok", reason)
        self.assertIn("Address = 10.77.0.2/32", config)


if __name__ == "__main__":
    unittest.main()
