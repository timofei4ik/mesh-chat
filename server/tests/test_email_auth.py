import asyncio
import tempfile
import unittest
from pathlib import Path

from server import server as server_module
from server import server_auth, server_email_auth, server_storage


class EmailAuthTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.previous_db_path = server_storage.DB_PATH
        self.previous_iterations = server_auth.PASSWORD_ITERATIONS
        self.previous_secret = server_email_auth.EMAIL_2FA_SECRET
        self.previous_legacy_allowed = (
            server_module.EMAIL_2FA_LEGACY_CLIENTS_ALLOWED
        )
        server_storage.DB_PATH = Path(self.temp_dir.name) / "server.db"
        server_auth.PASSWORD_ITERATIONS = 1_000
        server_email_auth.EMAIL_2FA_SECRET = "test-only-email-secret"
        self.relay = server_module.MeshRelayServer()
        self.sent_codes = []
        self.relay.send_email_verification_code = (
            lambda email, code, purpose: self.sent_codes.append(
                (email, code, purpose)
            )
        )

    def tearDown(self):
        self.relay.db.close()
        server_storage.DB_PATH = self.previous_db_path
        server_auth.PASSWORD_ITERATIONS = self.previous_iterations
        server_email_auth.EMAIL_2FA_SECRET = self.previous_secret
        server_module.EMAIL_2FA_LEGACY_CLIENTS_ALLOWED = (
            self.previous_legacy_allowed
        )
        self.temp_dir.cleanup()

    def test_code_is_hashed_and_can_only_be_consumed_once(self):
        challenge, reason = self.relay.issue_email_challenge(
            "alice",
            "phone",
            "Alice@Example.com",
            "registration",
        )
        self.assertEqual("ok", reason)
        code = self.sent_codes[0][1]
        stored = self.relay.db.execute(
            "SELECT code_hash FROM email_auth_challenges WHERE challenge_id=?",
            (challenge["challenge_id"],),
        ).fetchone()[0]
        self.assertNotEqual(code, stored)

        ok, reason, email = self.relay.verify_email_challenge(
            challenge["challenge_id"],
            "alice",
            "phone",
            code,
            "registration",
        )
        self.assertTrue(ok, reason)
        self.assertEqual("alice@example.com", email)
        second_ok, _, _ = self.relay.verify_email_challenge(
            challenge["challenge_id"],
            "alice",
            "phone",
            code,
            "registration",
        )
        self.assertFalse(second_ok)

    def test_legacy_account_requires_binding_then_trusts_device(self):
        ok, _ = self.relay.authenticate_account(
            "legacy",
            "password123",
            "old-phone",
            "Legacy",
        )
        self.assertTrue(ok)
        self.assertTrue(self.relay.email_binding_required("legacy"))

        challenge, _ = self.relay.issue_email_challenge(
            "legacy",
            "old-phone",
            "legacy@example.com",
            "binding",
        )
        code = self.sent_codes[-1][1]
        verified, _, email = self.relay.verify_email_challenge(
            challenge["challenge_id"],
            "legacy",
            "old-phone",
            code,
            "binding",
        )
        self.assertTrue(verified)
        bound, reason = self.relay.bind_account_email(
            "legacy",
            email,
            "old-phone",
        )
        self.assertTrue(bound, reason)
        self.assertFalse(self.relay.email_binding_required("legacy"))
        self.assertTrue(
            self.relay.is_email_device_trusted("legacy", "old-phone")
        )

    def test_new_registration_requires_code_before_account_creation(self):
        packet = {
            "supports_email_2fa": True,
            "email": "new@example.com",
        }
        ok, response, _ = asyncio.run(
            self.relay.authorize_email_2fa(
                packet,
                "new-user",
                "password123",
                "new-phone",
            )
        )
        self.assertFalse(ok)
        self.assertEqual("email_verification_required", response["code"])
        self.assertFalse(self.relay.account_exists("new-user"))

        packet.update(
            {
                "email_challenge_id": response["challenge_id"],
                "email_code": self.sent_codes[-1][1],
            }
        )
        ok, response, verified_email = asyncio.run(
            self.relay.authorize_email_2fa(
                packet,
                "new-user",
                "password123",
                "new-phone",
            )
        )
        self.assertTrue(ok, response)
        self.assertEqual("new@example.com", verified_email)
        created, reason = self.relay.authenticate_account(
            "new-user",
            "password123",
            "new-phone",
            "New User",
            email=verified_email,
            email_verified=True,
        )
        self.assertTrue(created, reason)
        row = self.relay.db.execute(
            "SELECT email, email_verified_at FROM accounts WHERE login='new-user'"
        ).fetchone()
        self.assertEqual("new@example.com", row[0])
        self.assertIsNotNone(row[1])

    def test_legacy_client_rollout_can_be_disabled_server_side(self):
        packet = {"supports_email_2fa": False}
        ok, response, _ = asyncio.run(
            self.relay.authorize_email_2fa(
                packet,
                "legacy-client",
                "password123",
                "legacy-phone",
            )
        )
        self.assertTrue(ok, response)

        server_module.EMAIL_2FA_LEGACY_CLIENTS_ALLOWED = False
        ok, response, _ = asyncio.run(
            self.relay.authorize_email_2fa(
                packet,
                "blocked-legacy-client",
                "password123",
                "legacy-phone",
            )
        )
        self.assertFalse(ok)
        self.assertEqual("email_2fa_update_required", response["code"])

    def test_account_delete_removes_account_and_owned_group(self):
        self.relay.authenticate_account(
            "owner",
            "password123",
            "owner-node",
            "Owner",
        )
        self.relay.db.execute(
            "INSERT INTO server_groups(group_id, group_name, owner_node) VALUES(?,?,?)",
            ("owned-group", "Owned", "owner-node"),
        )
        self.relay.db.execute(
            "INSERT INTO server_group_members(group_id,node_id,login) VALUES(?,?,?)",
            ("owned-group", "owner-node", "owner"),
        )
        self.relay.db.commit()

        ok, reason = self.relay.delete_account("owner", "password123")
        self.assertTrue(ok, reason)
        self.assertIsNone(
            self.relay.db.execute(
                "SELECT 1 FROM accounts WHERE login='owner'"
            ).fetchone()
        )
        self.assertIsNone(
            self.relay.db.execute(
                "SELECT 1 FROM server_groups WHERE group_id='owned-group'"
            ).fetchone()
        )


if __name__ == "__main__":
    unittest.main()
