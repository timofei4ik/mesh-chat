import sqlite3
import unittest
from contextlib import contextmanager

from server.persistence import SQLiteUnitOfWorkFactory


class SQLiteUnitOfWorkTests(unittest.TestCase):
    def setUp(self):
        self.connection = sqlite3.connect(":memory:")
        self.connection.execute(
            """
            CREATE TABLE accounts(
                login TEXT PRIMARY KEY,
                password_salt TEXT NOT NULL DEFAULT '',
                password_hash TEXT NOT NULL DEFAULT '',
                node_id TEXT,
                display_name TEXT,
                public_username TEXT,
                about TEXT,
                avatar_data TEXT,
                encryption_public_key TEXT,
                profile_background TEXT DEFAULT 'mesh',
                profile_effect TEXT DEFAULT 'stars',
                profile_blink_shape TEXT DEFAULT 'auto',
                avatar_decoration TEXT DEFAULT 'none',
                profile_glow INTEGER NOT NULL DEFAULT 0,
                profile_accent INTEGER NOT NULL DEFAULT 4282557941,
                emoji_status TEXT DEFAULT '',
                last_login DATETIME
            )
            """
        )
        self.connection.execute(
            """
            CREATE TABLE account_devices(
                login TEXT NOT NULL,
                node_id TEXT NOT NULL,
                display_name TEXT,
                custom_name TEXT,
                device_name TEXT,
                app_version TEXT,
                online INTEGER NOT NULL DEFAULT 0,
                revoked INTEGER NOT NULL DEFAULT 0,
                last_seen DATETIME
            )
            """
        )
        self.connection.execute(
            """
            CREATE TABLE account_subscriptions(
                login TEXT NOT NULL,
                product TEXT NOT NULL,
                plan_code TEXT,
                status TEXT,
                current_period_start DATETIME,
                current_period_end DATETIME,
                cancel_at_period_end INTEGER NOT NULL DEFAULT 0,
                provider TEXT,
                provider_customer_id TEXT,
                provider_subscription_id TEXT,
                updated_at DATETIME,
                PRIMARY KEY(login, product)
            )
            """
        )
        self.connection.execute(
            """
            CREATE TABLE subscription_events(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                login TEXT NOT NULL,
                product TEXT NOT NULL,
                event_type TEXT NOT NULL,
                provider_event_id TEXT UNIQUE,
                payload_json TEXT
            )
            """
        )
        self.connection.execute(
            """
            CREATE TABLE subscription_orders(
                order_id TEXT PRIMARY KEY,
                checkout_key TEXT NOT NULL UNIQUE,
                login TEXT NOT NULL,
                product TEXT NOT NULL,
                plan_code TEXT NOT NULL,
                duration_days INTEGER NOT NULL,
                amount_value TEXT NOT NULL,
                currency TEXT NOT NULL DEFAULT 'RUB',
                provider TEXT NOT NULL,
                provider_payment_id TEXT,
                status TEXT NOT NULL DEFAULT 'creating',
                confirmation_url TEXT NOT NULL DEFAULT '',
                payment_method_id TEXT NOT NULL DEFAULT '',
                buyer_email TEXT NOT NULL DEFAULT '',
                provider_product_id TEXT NOT NULL DEFAULT '',
                provider_offer_id TEXT NOT NULL DEFAULT '',
                paid_at DATETIME,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )
        self.connection.execute(
            """
            CREATE TABLE service_sessions(
                token_hash TEXT PRIMARY KEY,
                login TEXT NOT NULL,
                service TEXT NOT NULL,
                device_id TEXT,
                expires_at DATETIME NOT NULL,
                last_used_at DATETIME,
                revoked_at DATETIME
            )
            """
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

        self.factory = SQLiteUnitOfWorkFactory(
            self.connection,
            transaction,
        )

    def tearDown(self):
        self.connection.close()

    def test_identity_repository_normalizes_login_and_maps_devices(self):
        self.connection.executemany(
            """
            INSERT INTO account_devices(
                login,
                node_id,
                display_name,
                custom_name,
                device_name,
                app_version,
                online,
                revoked,
                last_seen
            )
            VALUES(?,?,?,?,?,?,?,?,?)
            """,
            [
                (
                    "alice",
                    "phone",
                    "Alice",
                    "My phone",
                    "Android",
                    "1.0",
                    1,
                    0,
                    "2026-07-23 12:00:00",
                ),
                (
                    "alice",
                    "old-phone",
                    "Alice",
                    None,
                    "Old phone",
                    "0.9",
                    1,
                    1,
                    "2026-07-22 12:00:00",
                ),
            ],
        )
        self.connection.commit()

        with self.factory() as unit_of_work:
            devices = unit_of_work.identity.get_account_devices(" ALICE ")

        self.assertEqual(["phone", "old-phone"], [
            item["node_id"] for item in devices
        ])
        self.assertTrue(devices[0]["online"])
        self.assertFalse(devices[1]["online"])
        self.assertTrue(devices[1]["revoked"])
        self.assertEqual("My phone", devices[0]["device_name"])

    def test_identity_repository_round_trips_profile_and_active_node(self):
        self.connection.execute(
            """
            INSERT INTO accounts(
                login,
                node_id,
                display_name,
                public_username
            )
            VALUES('alice', 'desktop', 'Alice', 'alice')
            """
        )
        self.connection.executemany(
            """
            INSERT INTO account_devices(
                login,
                node_id,
                device_name,
                online,
                revoked,
                last_seen
            )
            VALUES(?,?,?,?,?,?)
            """,
            [
                (
                    "alice",
                    "desktop",
                    "Desktop",
                    0,
                    0,
                    "2026-07-22 12:00:00",
                ),
                (
                    "alice",
                    "phone",
                    "Phone",
                    1,
                    0,
                    "2026-07-23 12:00:00",
                ),
            ],
        )
        self.connection.commit()

        with self.factory(write=True) as unit_of_work:
            unit_of_work.identity.update_profile(
                " ALICE ",
                {
                    "node_id": "phone",
                    "display_name": "Alice Updated",
                    "public_username": "alice",
                    "about": "Hello",
                    "avatar_data": "avatar",
                    "encryption_public_key": "public-key",
                    "profile_background": "aurora",
                    "profile_effect": "orbit",
                    "profile_blink_shape": "star",
                    "avatar_decoration": "stardust",
                    "profile_glow": 1,
                    "profile_accent": 0xFF00FFFF,
                    "emoji_status": "online",
                },
            )

        with self.factory() as unit_of_work:
            by_username = (
                unit_of_work.identity.profile_by_public_username("@Alice")
            )
            by_node = unit_of_work.identity.profile_by_node("phone")
            login = unit_of_work.identity.login_by_node("phone")

        self.assertEqual("alice", login)
        self.assertEqual("phone", by_username["node_id"])
        self.assertEqual("Alice Updated", by_username["display_name"])
        self.assertEqual("aurora", by_node["profile_background"])
        self.assertEqual("orbit", by_node["profile_effect"])
        self.assertEqual("online", by_node["emoji_status"])
        self.assertTrue(by_node["profile_glow"])

    def test_write_unit_of_work_rolls_back_on_failure(self):
        with self.assertRaisesRegex(RuntimeError, "stop"):
            with self.factory(write=True):
                self.connection.execute(
                    """
                    INSERT INTO account_devices(login, node_id)
                    VALUES('alice', 'phone')
                    """
                )
                raise RuntimeError("stop")

        count = self.connection.execute(
            "SELECT COUNT(*) FROM account_devices"
        ).fetchone()[0]
        self.assertEqual(0, count)

    def test_write_unit_of_work_commits_on_success(self):
        with self.factory(write=True):
            self.connection.execute(
                """
                INSERT INTO account_devices(login, node_id)
                VALUES('alice', 'phone')
                """
            )

        count = self.connection.execute(
            "SELECT COUNT(*) FROM account_devices"
        ).fetchone()[0]
        self.assertEqual(1, count)

    def test_subscription_repository_grants_and_deduplicates_events(self):
        self.connection.execute(
            "INSERT INTO accounts(login) VALUES('alice')"
        )
        self.connection.commit()

        with self.factory(write=True) as unit_of_work:
            unit_of_work.subscriptions.grant(
                " ALICE ",
                "meshpro",
                "monthly",
                30,
                "boosty",
                "subscription-1",
            )
            unit_of_work.subscriptions.record_event(
                "alice",
                "meshpro",
                "granted",
                {"days": 30},
                "boosty:event-1",
            )

        with self.factory() as unit_of_work:
            subscription = unit_of_work.subscriptions.subscription(
                "alice",
                "meshpro",
            )
            duplicate = (
                unit_of_work.subscriptions.provider_event_exists(
                    "boosty:event-1"
                )
            )

        self.assertEqual("monthly", subscription[0])
        self.assertEqual("active", subscription[1])
        self.assertEqual("boosty", subscription[5])
        self.assertTrue(duplicate)

    def test_subscription_repository_write_rolls_back_as_one_unit(self):
        with self.assertRaisesRegex(RuntimeError, "payment failed"):
            with self.factory(write=True) as unit_of_work:
                unit_of_work.subscriptions.grant(
                    "alice",
                    "meshpro",
                    "monthly",
                    30,
                    "manual",
                    "",
                )
                unit_of_work.subscriptions.record_event(
                    "alice",
                    "meshpro",
                    "granted",
                    {},
                    "manual:event-1",
                )
                raise RuntimeError("payment failed")

        subscriptions = self.connection.execute(
            "SELECT COUNT(*) FROM account_subscriptions"
        ).fetchone()[0]
        events = self.connection.execute(
            "SELECT COUNT(*) FROM subscription_events"
        ).fetchone()[0]
        self.assertEqual(0, subscriptions)
        self.assertEqual(0, events)

    def test_service_session_repository_is_device_bound_and_revocable(self):
        with self.factory(write=True) as unit_of_work:
            unit_of_work.subscriptions.create_service_session(
                "token-hash",
                "alice",
                "meshprivacy",
                "phone",
                30,
            )

        with self.factory() as unit_of_work:
            session = unit_of_work.subscriptions.service_session(
                "token-hash",
                "meshprivacy",
            )
        self.assertEqual(("alice", "phone"), session)

        with self.factory(write=True) as unit_of_work:
            unit_of_work.subscriptions.revoke_service_session(
                "token-hash",
                "meshprivacy",
            )
        with self.factory() as unit_of_work:
            self.assertIsNone(
                unit_of_work.subscriptions.service_session(
                    "token-hash",
                    "meshprivacy",
                )
            )

    def test_billing_repository_round_trips_checkout_and_status(self):
        with self.factory(write=True) as unit_of_work:
            unit_of_work.billing.create_order(
                {
                    "order_id": "order-1",
                    "checkout_key": "checkout-1",
                    "login": "alice",
                    "product": "meshpro",
                    "plan_code": "monthly",
                    "duration_days": 30,
                    "amount_value": "199.00",
                    "provider": "yookassa",
                    "status": "creating",
                }
            )

        with self.factory(write=True) as unit_of_work:
            unit_of_work.billing.set_provider_checkout(
                "order-1",
                "payment-1",
                "pending",
                "https://pay.example/order-1",
            )

        with self.factory() as unit_of_work:
            row = unit_of_work.billing.checkout_result("order-1")
            payment = unit_of_work.billing.yookassa_payment_order(
                "payment-1",
                "order-1",
            )

        self.assertEqual("pending", row[1])
        self.assertEqual("https://pay.example/order-1", row[2])
        self.assertEqual("alice", payment[1])
