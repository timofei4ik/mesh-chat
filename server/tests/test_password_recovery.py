import asyncio
import json
import tempfile
import unittest
from pathlib import Path

from server import server as server_module
from server import server_auth, server_email_auth, server_storage


class PasswordRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.previous_db_path = server_storage.DB_PATH
        self.previous_iterations = server_auth.PASSWORD_ITERATIONS
        self.previous_email_secret = server_email_auth.EMAIL_2FA_SECRET
        server_storage.DB_PATH = Path(self.temp_dir.name) / "server.db"
        server_auth.PASSWORD_ITERATIONS = 1_000
        server_email_auth.EMAIL_2FA_SECRET = "test-password-recovery-secret"
        self.relay = server_module.MeshRelayServer()

    def tearDown(self):
        self.relay.db.close()
        server_storage.DB_PATH = self.previous_db_path
        server_auth.PASSWORD_ITERATIONS = self.previous_iterations
        server_email_auth.EMAIL_2FA_SECRET = self.previous_email_secret
        self.temp_dir.cleanup()

    @staticmethod
    def recovery_envelope():
        return json.dumps(
            {
                "v": 1,
                "i": 300000,
                "s": "c2FsdA==",
                "n": "bm9uY2U=",
                "c": "Y2lwaGVydGV4dA==",
                "m": "bWFj",
            }
        )

    def test_password_change_replaces_auth_hash_and_keeps_recovery_opaque(self):
        ok, _ = self.relay.authenticate_account(
            "eblan4k",
            "old-password",
            "phone-node",
            "Eblan4k",
            public_username="eblan4k",
            encryption_public_key="existing-public-key",
        )
        self.assertTrue(ok)
        recovery = self.recovery_envelope()

        ok, reason = self.relay.change_account_password(
            "eblan4k",
            "old-password",
            "new-password",
            recovery,
        )
        self.assertTrue(ok, reason)
        self.assertEqual(
            recovery,
            self.relay.get_account_encryption_recovery("eblan4k"),
        )

        old_ok, _ = self.relay.authenticate_account(
            "eblan4k",
            "old-password",
            "old-check",
            "Eblan4k",
            verify_only=True,
            allow_registration=False,
        )
        new_ok, _ = self.relay.authenticate_account(
            "eblan4k",
            "new-password",
            "new-check",
            "Eblan4k",
            verify_only=True,
            allow_registration=False,
        )
        self.assertFalse(old_ok)
        self.assertTrue(new_ok)

        row = self.relay.db.execute(
            """
            SELECT password_salt,
                   password_hash,
                   encryption_public_key
            FROM accounts
            WHERE login='eblan4k'
            """
        ).fetchone()
        self.assertNotIn("new-password", row)
        self.assertEqual("existing-public-key", row[2])

    def test_password_change_rejects_bad_current_password_and_envelope(self):
        self.relay.authenticate_account(
            "eblan4k",
            "old-password",
            "phone-node",
            "Eblan4k",
            public_username="eblan4k",
        )

        ok, reason = self.relay.change_account_password(
            "eblan4k",
            "wrong-password",
            "new-password",
            self.recovery_envelope(),
        )
        self.assertFalse(ok)
        self.assertEqual("invalid_current_password", reason)

        ok, reason = self.relay.change_account_password(
            "eblan4k",
            "old-password",
            "new-password",
            "not-json",
        )
        self.assertFalse(ok)
        self.assertEqual("invalid_encryption_recovery", reason)

    def test_email_reset_replaces_identity_and_revokes_other_devices(self):
        ok, reason = self.relay.authenticate_account(
            "recover-me",
            "old-password",
            "old-phone",
            "Recover Me",
            email="recover@example.com",
            email_verified=True,
        )
        self.assertTrue(ok, reason)
        self.relay.save_account_device("recover-me", "old-phone")
        self.relay.save_account_device("recover-me", "desktop")
        self.relay.send_email_verification_code = lambda email, code, purpose: (
            setattr(self, "reset_code", code)
        )

        challenge, reason = asyncio.run(
            self.relay.request_password_reset("recover-me", "new-phone")
        )
        self.assertEqual("ok", reason)
        self.assertEqual("password_reset", challenge["purpose"])

        ok, reason, login = self.relay.confirm_password_reset(
            "recover-me",
            "new-phone",
            challenge["challenge_id"],
            self.reset_code,
            "new-password",
            self.recovery_envelope(),
            "new-public-key",
        )
        self.assertTrue(ok, reason)
        self.assertEqual("recover-me", login)
        self.assertTrue(
            self.relay.verify_account_password("recover-me", "new-password")
        )
        self.assertFalse(
            self.relay.verify_account_password("recover-me", "old-password")
        )
        self.assertTrue(
            self.relay.is_email_device_trusted("recover-me", "new-phone")
        )
        devices = {
            item["node_id"]: item
            for item in self.relay.get_account_devices("recover-me")
        }
        self.assertTrue(devices["old-phone"]["revoked"])
        self.assertTrue(devices["desktop"]["revoked"])

    def test_repeated_bad_passwords_are_temporarily_blocked(self):
        self.relay.authenticate_account(
            "rate-limited",
            "correct-password",
            "phone",
            "Rate Limited",
            email="rate@example.com",
            email_verified=True,
        )
        packet = {
            "supports_email_2fa": True,
            "register_if_missing": False,
        }
        for _ in range(self.relay._AUTH_PAIR_LIMIT):
            ok, response, _ = asyncio.run(
                self.relay.authorize_email_2fa(
                    packet,
                    "rate-limited",
                    "wrong-password",
                    "attacker-device",
                )
            )
            self.assertFalse(ok)
            self.assertEqual("authentication_failed", response["code"])

        ok, response, _ = asyncio.run(
            self.relay.authorize_email_2fa(
                packet,
                "rate-limited",
                "wrong-password",
                "attacker-device",
            )
        )
        self.assertFalse(ok)
        self.assertEqual("authentication_rate_limited", response["code"])
        self.assertGreater(response["retry_after"], 0)


if __name__ == "__main__":
    unittest.main()
