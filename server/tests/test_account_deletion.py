import sqlite3
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path

from server import server as server_module
from server import server_storage
from server.account_deletion import (
    AccountDataPolicy,
    AccountDeletionContext,
    AccountDeletionOrchestrator,
)


class StaticContextLoader:
    def __init__(self, context):
        self.context = context

    def load(self, login):
        self.context.login = login
        return self.context


class DeleteAccountOwner:
    name = "identity"
    policies = (AccountDataPolicy("identity", "accounts"),)

    def __init__(self, connection):
        self.connection = connection

    def delete_account(self, context):
        self.connection.execute(
            "DELETE FROM accounts WHERE login=?",
            (context.login,),
        )


class FailingOwner:
    name = "failing"
    policies = ()

    def delete_account(self, context):
        raise RuntimeError("owner failed")


class AccountDeletionOrchestratorTests(unittest.TestCase):
    def setUp(self):
        self.connection = sqlite3.connect(":memory:")
        self.connection.execute(
            "CREATE TABLE accounts(login TEXT PRIMARY KEY)"
        )
        self.connection.execute(
            "INSERT INTO accounts(login) VALUES('alice')"
        )
        self.connection.commit()

        @contextmanager
        def transaction():
            self.connection.execute("BEGIN IMMEDIATE")
            try:
                yield
            except BaseException:
                self.connection.rollback()
                raise
            else:
                self.connection.commit()

        self.transaction = transaction
        self.temp_dir = tempfile.TemporaryDirectory()
        self.stored_file = Path(self.temp_dir.name) / "avatar.bin"
        self.stored_file.write_bytes(b"avatar")

    def tearDown(self):
        self.connection.close()
        self.temp_dir.cleanup()

    def test_owner_failure_rolls_back_and_keeps_files(self):
        orchestrator = AccountDeletionOrchestrator(
            StaticContextLoader(
                AccountDeletionContext(
                    login="alice",
                    stored_paths=[str(self.stored_file)],
                )
            ),
            [
                DeleteAccountOwner(self.connection),
                FailingOwner(),
            ],
            self.transaction,
        )

        with self.assertRaisesRegex(RuntimeError, "owner failed"):
            orchestrator.delete("alice")

        self.assertIsNotNone(
            self.connection.execute(
                "SELECT 1 FROM accounts WHERE login='alice'"
            ).fetchone()
        )
        self.assertTrue(self.stored_file.exists())

    def test_files_are_removed_only_after_successful_commit(self):
        orchestrator = AccountDeletionOrchestrator(
            StaticContextLoader(
                AccountDeletionContext(
                    login="alice",
                    stored_paths=[str(self.stored_file)],
                )
            ),
            [DeleteAccountOwner(self.connection)],
            self.transaction,
        )

        orchestrator.delete("alice")

        self.assertIsNone(
            self.connection.execute(
                "SELECT 1 FROM accounts WHERE login='alice'"
            ).fetchone()
        )
        self.assertFalse(self.stored_file.exists())


class AccountDeletionPolicyTests(unittest.TestCase):
    ACCOUNT_LINK_COLUMNS = {
        "login",
        "account_login",
        "owner_login",
        "sender_login",
        "receiver_login",
        "member_login",
        "reactor_login",
        "viewer_login",
        "pinner_login",
        "redeemed_login",
        "owner_node",
        "destination_node",
    }

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.previous_db_path = server_storage.DB_PATH
        server_storage.DB_PATH = Path(self.temp_dir.name) / "server.db"
        self.relay = server_module.MeshRelayServer()

    def tearDown(self):
        self.relay.db.close()
        server_storage.DB_PATH = self.previous_db_path
        self.temp_dir.cleanup()

    def test_every_account_scoped_table_has_a_policy(self):
        account_scoped_tables = set()
        table_names = [
            row[0]
            for row in self.relay.db.execute(
                """
                SELECT name
                FROM sqlite_master
                WHERE type='table' AND name NOT LIKE 'sqlite_%'
                """
            ).fetchall()
        ]
        for table_name in table_names:
            columns = {
                row[1]
                for row in self.relay.db.execute(
                    f"PRAGMA table_info({table_name})"
                ).fetchall()
            }
            if columns & self.ACCOUNT_LINK_COLUMNS:
                account_scoped_tables.add(table_name)

        policy_tables = {
            policy.table
            for policy in self.relay.account_deletion_orchestrator.policies
        }
        self.assertEqual(set(), account_scoped_tables - policy_tables)

    def test_each_table_has_one_authoritative_owner(self):
        policies = self.relay.account_deletion_orchestrator.policies
        tables = [policy.table for policy in policies]
        self.assertEqual(len(tables), len(set(tables)))
