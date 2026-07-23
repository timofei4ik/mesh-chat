import os
import re
import tempfile
import unittest
from pathlib import Path

from server.persistence.postgres import (
    apply_postgres_migrations,
    translate_sqlite_query,
)
from server.persistence.postgres_billing import PostgresBillingRepository
from server.persistence.sqlite_billing import SQLiteBillingRepository


class _FakeTransaction:
    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return False


class _FakeCursor:
    def __init__(self, connection):
        self.connection = connection
        self.rows = []

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return False

    def execute(self, query, parameters=(), **kwargs):
        normalized = " ".join(str(query).split()).lower()
        self.connection.executed.append((str(query), parameters, kwargs))
        if normalized.startswith("select version from schema_migrations"):
            self.rows = [(item,) for item in self.connection.applied]
        elif normalized.startswith(
            "insert into schema_migrations(version)"
        ):
            self.connection.applied.add(parameters[0])

    def fetchall(self):
        return list(self.rows)


class _FakeConnection:
    def __init__(self):
        self.applied = set()
        self.executed = []

    def transaction(self):
        return _FakeTransaction()

    def cursor(self):
        return _FakeCursor(self)


class PostgresPersistenceTests(unittest.TestCase):
    def test_migrations_apply_in_order_and_only_once(self):
        connection = _FakeConnection()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "002_second.sql").write_text(
                "SELECT 'second';",
                encoding="utf-8",
            )
            (root / "001_first.sql").write_text(
                "SELECT 'first';",
                encoding="utf-8",
            )

            apply_postgres_migrations(connection, root)
            first_run = [
                query
                for query, _, options in connection.executed
                if options.get("prepare") is False
            ]
            apply_postgres_migrations(connection, root)
            all_runs = [
                query
                for query, _, options in connection.executed
                if options.get("prepare") is False
            ]

        self.assertEqual(
            ["SELECT 'first';", "SELECT 'second';"],
            first_run,
        )
        self.assertEqual(first_run, all_runs)
        self.assertEqual(
            {"001_first", "002_second"},
            connection.applied,
        )

    def test_checked_in_migrations_are_postgres_native(self):
        migration_dir = (
            Path(__file__).resolve().parents[1]
            / "persistence"
            / "postgres_migrations"
        )
        migrations = sorted(migration_dir.glob("*.sql"))

        self.assertEqual(
            [
                "001_accounts_core.sql",
                "002_billing.sql",
                "003_server_data.sql",
                "004_migration_support.sql",
            ],
            [item.name for item in migrations],
        )
        combined = "\n".join(
            item.read_text(encoding="utf-8").lower()
            for item in migrations
        )
        for sqlite_token in (
            "autoincrement",
            "datetime('now'",
            "insert or ignore",
        ):
            self.assertNotIn(sqlite_token, combined)
        self.assertIn("references accounts(login)", combined)

    def test_postgres_schema_covers_every_server_table(self):
        server_storage = (
            Path(__file__).resolve().parents[1]
            / "server_storage.py"
        ).read_text(encoding="utf-8")
        sqlite_tables = set(
            re.findall(
                r"(?is)CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+"
                r"([A-Za-z_][A-Za-z0-9_]*)",
                server_storage,
            )
        )
        sqlite_tables.discard("server_chat_deletes_new")

        migration_dir = (
            Path(__file__).resolve().parents[1]
            / "persistence"
            / "postgres_migrations"
        )
        postgres_sql = "\n".join(
            item.read_text(encoding="utf-8")
            for item in sorted(migration_dir.glob("*.sql"))
        )
        postgres_tables = set(
            re.findall(
                r"(?is)CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+"
                r"([A-Za-z_][A-Za-z0-9_]*)",
                postgres_sql,
            )
        )

        self.assertEqual(
            set(),
            sqlite_tables.difference(postgres_tables),
        )

    def test_compatibility_translates_time_and_scalar_max(self):
        query, capture_identity = translate_sqlite_query(
            """
            UPDATE meshpro_usage
            SET used_count=MAX(used_count - ?, 0)
            WHERE updated_at < DATETIME('now', ?)
            """
        )

        self.assertFalse(capture_identity)
        self.assertIn(
            "GREATEST(used_count - %s, 0)",
            query,
        )
        self.assertIn(
            "CURRENT_TIMESTAMP + CAST(%s AS INTERVAL)",
            query,
        )

    def test_compatibility_translates_datetime_case_modifier(self):
        query, capture_identity = translate_sqlite_query(
            """
            UPDATE account_subscriptions
            SET current_period_end=DATETIME(
                CASE
                    WHEN current_period_end > CURRENT_TIMESTAMP
                    THEN current_period_end
                    ELSE CURRENT_TIMESTAMP
                END,
                ?
            )
            """
        )

        self.assertFalse(capture_identity)
        self.assertNotIn("DATETIME(", query.upper())
        self.assertIn("CAST(%s AS INTERVAL)", query)

    def test_compatibility_translates_ignore_and_sync_identity(self):
        query, capture_identity = translate_sqlite_query(
            """
            INSERT OR IGNORE INTO sync_events(
                account_login, operation_id, packet_type, payload_json
            )
            VALUES(?,?,?,?)
            """
        )

        self.assertTrue(capture_identity)
        self.assertIn("ON CONFLICT DO NOTHING", query)
        self.assertTrue(query.endswith("RETURNING event_id"))
        self.assertEqual(4, query.count("%s"))

    def test_compatibility_translates_known_replace_upsert(self):
        query, capture_identity = translate_sqlite_query(
            """
            INSERT OR REPLACE INTO server_group_members(
                group_id, node_id, login
            )
            VALUES(?,?,?)
            """
        )

        self.assertFalse(capture_identity)
        self.assertIn(
            "ON CONFLICT(group_id, node_id) DO UPDATE SET",
            query,
        )
        self.assertIn("login=EXCLUDED.login", query)

    def test_compatibility_qualifies_ambiguous_upsert_columns(self):
        query, capture_identity = translate_sqlite_query(
            """
            INSERT INTO account_devices(
                login, node_id, display_name, device_name, app_version
            )
            VALUES(?,?,?,?,?)
            ON CONFLICT(login, node_id) DO UPDATE SET
                display_name=COALESCE(excluded.display_name, display_name),
                device_name=COALESCE(excluded.device_name, device_name),
                app_version=COALESCE(excluded.app_version, app_version)
            """
        )

        self.assertFalse(capture_identity)
        for column in ("display_name", "device_name", "app_version"):
            self.assertIn(
                f"COALESCE(excluded.{column}, account_devices.{column})",
                query,
            )

    def test_billing_adapters_implement_the_same_surface(self):
        methods = {
            "reusable_order",
            "order_by_checkout_key",
            "create_order",
            "set_checkout_error",
            "set_provider_checkout",
            "checkout_result",
            "manual_status",
            "mark_manual_submitted",
            "list_manual_orders",
            "manual_approval_row",
            "manual_result",
            "manual_admin_result",
            "manual_ids_by_prefix",
            "set_order_status",
            "lava_notification_order",
            "yookassa_payment_order",
            "cancel_yookassa_payment",
            "mark_yookassa_succeeded",
        }
        for adapter in (
            SQLiteBillingRepository,
            PostgresBillingRepository,
        ):
            missing = {
                name
                for name in methods
                if not callable(getattr(adapter, name, None))
            }
            self.assertEqual(set(), missing, adapter.__name__)

    @unittest.skipUnless(
        os.environ.get("MESH_TEST_POSTGRES_URL"),
        "MESH_TEST_POSTGRES_URL is not configured",
    )
    def test_real_postgres_migrations_are_idempotent(self):
        from server.persistence.postgres import connect_postgres

        connection = connect_postgres(
            os.environ["MESH_TEST_POSTGRES_URL"],
        )
        try:
            apply_postgres_migrations(connection)
            apply_postgres_migrations(connection)
            with connection.cursor() as cursor:
                cursor.execute(
                    "SELECT version FROM schema_migrations ORDER BY version"
                )
                versions = [row[0] for row in cursor.fetchall()]
            self.assertIn("001_accounts_core", versions)
            self.assertIn("002_billing", versions)
        finally:
            connection.close()
