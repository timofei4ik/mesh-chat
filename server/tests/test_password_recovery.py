import json
import tempfile
import unittest
from pathlib import Path

from server import server as server_module
from server import server_auth, server_storage


class PasswordRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.previous_db_path = server_storage.DB_PATH
        self.previous_iterations = server_auth.PASSWORD_ITERATIONS
        server_storage.DB_PATH = Path(self.temp_dir.name) / "server.db"
        server_auth.PASSWORD_ITERATIONS = 1_000
        self.relay = server_module.MeshRelayServer()

    def tearDown(self):
        self.relay.db.close()
        server_storage.DB_PATH = self.previous_db_path
        server_auth.PASSWORD_ITERATIONS = self.previous_iterations
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


if __name__ == "__main__":
    unittest.main()
