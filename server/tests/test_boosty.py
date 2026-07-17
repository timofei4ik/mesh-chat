import tempfile
import unittest
from pathlib import Path

from server import (
    server_auth,
    server_boosty,
    server_storage,
    server_subscription,
)


class BoostyRelay(
    server_storage.ServerStorageMixin,
    server_auth.ServerAuthMixin,
    server_boosty.ServerBoostyMixin,
    server_subscription.ServerSubscriptionMixin,
):
    def __init__(self):
        self.member_state = True
        self.membership_error = False
        self.owner_state = True
        self.owner_user_id = 701
        self.send_error = False
        self.sent_messages = []
        self.revoked_devices = []
        self.db = self.open_db()

    async def _boosty_user_is_member(self, telegram_user_id):
        if self.membership_error:
            raise server_boosty.BoostyTelegramError("telegram_unavailable")
        return self.member_state

    async def _boosty_get_chat_member(self, chat_id, telegram_user_id):
        return {
            "status": (
                "creator"
                if self.owner_state and int(telegram_user_id) == self.owner_user_id
                else "administrator"
            )
        }

    async def _boosty_send_message(
        self,
        chat_id,
        text,
        reply_markup=None,
    ):
        if self.send_error:
            raise server_boosty.BoostyTelegramError("telegram_send_failed")
        self.sent_messages.append((chat_id, text, reply_markup))

    def revoke_wireguard_peers(
        self,
        login,
        product="meshpro",
        device_id=None,
    ):
        self.revoked_devices.append((login, product, device_id))
        return []


class BoostyTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.previous = {
            "db_path": server_storage.DB_PATH,
            "secret": server_boosty.BOOSTY_ACTIVATION_SECRET,
            "token": server_boosty.BOOSTY_TELEGRAM_BOT_TOKEN,
            "group": server_boosty.BOOSTY_TELEGRAM_GROUP_ID,
            "owner": server_boosty.BOOSTY_TELEGRAM_OWNER_ID,
            "url": server_boosty.BOOSTY_ACTIVATION_URL,
            "duration": server_boosty.BOOSTY_KEY_DURATION_DAYS,
            "interval": server_boosty.BOOSTY_KEY_ISSUE_INTERVAL_DAYS,
            "aiohttp": server_boosty.aiohttp,
        }
        server_storage.DB_PATH = Path(self.temp_dir.name) / "server.db"
        server_boosty.BOOSTY_ACTIVATION_SECRET = "s" * 48
        server_boosty.BOOSTY_TELEGRAM_BOT_TOKEN = "test-bot-token"
        server_boosty.BOOSTY_TELEGRAM_GROUP_ID = "-1001234567890"
        server_boosty.BOOSTY_TELEGRAM_OWNER_ID = "701"
        server_boosty.BOOSTY_ACTIVATION_URL = (
            "https://mesh.example/meshpro/activate"
        )
        server_boosty.BOOSTY_KEY_DURATION_DAYS = 30
        server_boosty.BOOSTY_KEY_ISSUE_INTERVAL_DAYS = 30
        server_boosty.aiohttp = object()
        self.relay = BoostyRelay()
        server_boosty.BOOSTY_TELEGRAM_OWNER_ID = str(
            self.relay.owner_user_id
        )
        self.assertEqual(
            (True, "registered"),
            self.relay.authenticate_account(
                "subscriber",
                "correct-password",
                "node-a",
                "Subscriber",
            ),
        )
        self.assertEqual(
            (True, "registered"),
            self.relay.authenticate_account(
                "other",
                "other-password",
                "node-b",
                "Other",
            ),
        )

    async def asyncTearDown(self):
        self.relay.db.close()
        server_storage.DB_PATH = self.previous["db_path"]
        server_boosty.BOOSTY_ACTIVATION_SECRET = self.previous["secret"]
        server_boosty.BOOSTY_TELEGRAM_BOT_TOKEN = self.previous["token"]
        server_boosty.BOOSTY_TELEGRAM_GROUP_ID = self.previous["group"]
        server_boosty.BOOSTY_TELEGRAM_OWNER_ID = self.previous["owner"]
        server_boosty.BOOSTY_ACTIVATION_URL = self.previous["url"]
        server_boosty.BOOSTY_KEY_DURATION_DAYS = self.previous["duration"]
        server_boosty.BOOSTY_KEY_ISSUE_INTERVAL_DAYS = self.previous[
            "interval"
        ]
        server_boosty.aiohttp = self.previous["aiohttp"]
        self.temp_dir.cleanup()

    def _register_recipient(self, telegram_user_id, username="subscriber_tg"):
        self.relay._boosty_register_recipient(
            {
                "from": {
                    "id": telegram_user_id,
                    "username": username,
                },
                "chat": {
                    "id": telegram_user_id,
                    "type": "private",
                },
            }
        )

    def test_schema_contains_key_metadata_and_recipient_schedule(self):
        columns = {
            row[1]
            for row in self.relay.db.execute(
                "PRAGMA table_info(boosty_activation_codes)"
            ).fetchall()
        }
        self.assertTrue(
            {"duration_days", "issue_kind", "redeemed_login"} <= columns
        )
        table = self.relay.db.execute(
            """
            SELECT name
            FROM sqlite_master
            WHERE type='table' AND name='boosty_key_recipients'
            """
        ).fetchone()
        self.assertIsNotNone(table)

    async def test_gift_owner_requires_fixed_id_and_creator_status(self):
        self.assertTrue(
            await self.relay._boosty_user_is_owner(self.relay.owner_user_id)
        )
        self.assertFalse(
            await self.relay._boosty_user_is_owner(
                self.relay.owner_user_id + 1
            )
        )
        self.relay.owner_state = False
        self.assertFalse(
            await self.relay._boosty_user_is_owner(self.relay.owner_user_id)
        )

    async def test_gift_is_disabled_when_owner_id_is_missing(self):
        server_boosty.BOOSTY_TELEGRAM_OWNER_ID = ""
        self.assertFalse(
            await self.relay._boosty_user_is_owner(self.relay.owner_user_id)
        )

    async def test_gift_command_rejects_other_users(self):
        await self.relay._boosty_gift_command(
            {
                "chat": {"id": 702, "type": "private"},
                "from": {"id": 702, "username": "not_owner"},
            },
            "/gift 12",
        )
        count = self.relay.db.execute(
            "SELECT COUNT(*) FROM boosty_activation_codes"
        ).fetchone()[0]
        self.assertEqual(0, count)
        self.assertEqual(1, len(self.relay.sent_messages))

    async def test_gift_command_allows_configured_creator(self):
        await self.relay._boosty_gift_command(
            {
                "chat": {"id": 701, "type": "private"},
                "from": {"id": 701, "username": "owner"},
            },
            "/gift 12",
        )
        row = self.relay.db.execute(
            """
            SELECT duration_days, issue_kind
            FROM boosty_activation_codes
            """
        ).fetchone()
        self.assertEqual((360, "gift"), row)
        self.assertEqual(1, len(self.relay.sent_messages))

    async def test_gift_command_supports_two_week_key(self):
        await self.relay._boosty_gift_command(
            {
                "chat": {"id": 701, "type": "private"},
                "from": {"id": 701, "username": "owner"},
            },
            "/gift 14d",
        )
        row = self.relay.db.execute(
            """
            SELECT duration_days, issue_kind
            FROM boosty_activation_codes
            """
        ).fetchone()
        self.assertEqual((14, "gift"), row)

    def test_code_is_long_and_only_its_hmac_is_stored(self):
        code = self.relay.create_boosty_activation_code(101, "subscriber_tg")
        self.assertRegex(
            code,
            r"^MPR-(?:[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}-){4}"
            r"[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}$",
        )
        row = self.relay.db.execute(
            "SELECT code_hash FROM boosty_activation_codes"
        ).fetchone()
        self.assertEqual(64, len(row[0]))
        self.assertNotIn(code, row[0])
        dump = "\n".join(self.relay.db.iterdump())
        self.assertNotIn(code, dump)

    async def test_wrong_password_does_not_consume_code(self):
        code = self.relay.create_boosty_activation_code(102)
        with self.assertRaisesRegex(
            server_boosty.BoostyActivationError,
            "invalid_credentials",
        ):
            await self.relay.activate_boosty_subscription(
                "subscriber",
                "wrong-password",
                code,
            )
        consumed = self.relay.db.execute(
            "SELECT consumed_at FROM boosty_activation_codes"
        ).fetchone()[0]
        self.assertIsNone(consumed)

    async def test_key_is_transferable_and_does_not_recheck_membership(self):
        code = self.relay.create_boosty_activation_code(
            103,
            "subscriber_tg",
            duration_days=30,
        )
        self.relay.member_state = False
        result = await self.relay.activate_boosty_subscription(
            "other",
            "other-password",
            code.lower(),
        )
        self.assertEqual("other", result["login"])
        self.assertEqual(30, result["duration_days"])
        self.assertTrue(result["subscription"]["active"])
        self.assertEqual("boosty_key", result["subscription"]["provider"])

    async def test_key_is_one_time_and_records_redeemer(self):
        code = self.relay.create_boosty_activation_code(104)
        await self.relay.activate_boosty_subscription(
            "subscriber",
            "correct-password",
            code,
        )
        row = self.relay.db.execute(
            """
            SELECT consumed_at, redeemed_login
            FROM boosty_activation_codes
            """
        ).fetchone()
        self.assertIsNotNone(row[0])
        self.assertEqual("subscriber", row[1])
        with self.assertRaisesRegex(
            server_boosty.BoostyActivationError,
            "invalid_or_expired_code",
        ):
            await self.relay.activate_boosty_subscription(
                "other",
                "other-password",
                code,
            )

    async def test_multiple_keys_stack_their_durations(self):
        first_code = self.relay.create_boosty_activation_code(
            105,
            duration_days=30,
        )
        first = await self.relay.activate_boosty_subscription(
            "subscriber",
            "correct-password",
            first_code,
        )
        second_code = self.relay.create_boosty_activation_code(
            106,
            duration_days=90,
        )
        second = await self.relay.activate_boosty_subscription(
            "subscriber",
            "correct-password",
            second_code,
        )
        first_end = self.relay._parse_subscription_time(
            first["subscription"]["current_period_end"]
        )
        second_end = self.relay._parse_subscription_time(
            second["subscription"]["current_period_end"]
        )
        stacked_days = (second_end - first_end).total_seconds() / 86400
        self.assertAlmostEqual(90, stacked_days, delta=0.01)

    def test_subscriber_key_can_only_be_issued_once_per_interval(self):
        self._register_recipient(107)
        first_code, first_wait = self.relay.issue_monthly_boosty_key(107)
        second_code, second_wait = self.relay.issue_monthly_boosty_key(107)
        self.assertTrue(first_code)
        self.assertEqual(0, first_wait)
        self.assertIsNone(second_code)
        self.assertGreater(second_wait, 29 * 86400)
        count = self.relay.db.execute(
            """
            SELECT COUNT(*)
            FROM boosty_activation_codes
            WHERE telegram_user_id=107 AND issue_kind='subscriber'
            """
        ).fetchone()[0]
        self.assertEqual(1, count)

    async def test_reconcile_issues_due_key_to_active_recipient(self):
        self._register_recipient(108)
        stats = await self.relay.reconcile_boosty_memberships()
        self.assertEqual(1, stats["checked"])
        self.assertEqual(1, stats["active"])
        self.assertEqual(1, stats["issued"])
        self.assertEqual(1, len(self.relay.sent_messages))
        self.assertIn("Ежемесячный одноразовый ключ", self.relay.sent_messages[0][1])

        second = await self.relay.reconcile_boosty_memberships()
        self.assertEqual(0, second["issued"])
        self.assertEqual(1, len(self.relay.sent_messages))

    async def test_reconcile_does_not_issue_to_inactive_recipient(self):
        self._register_recipient(109)
        self.relay.member_state = False
        stats = await self.relay.reconcile_boosty_memberships()
        self.assertEqual(1, stats["inactive"])
        self.assertEqual(0, stats["issued"])
        self.assertEqual([], self.relay.sent_messages)

    async def test_failed_delivery_is_retried_without_losing_month(self):
        self._register_recipient(110)
        self.relay.send_error = True
        stats = await self.relay.reconcile_boosty_memberships()
        self.assertEqual(1, stats["errors"])
        count = self.relay.db.execute(
            """
            SELECT COUNT(*)
            FROM boosty_activation_codes
            WHERE telegram_user_id=110
            """
        ).fetchone()[0]
        self.assertEqual(0, count)
        self.assertEqual(0, self.relay._boosty_key_wait_seconds(110))


if __name__ == "__main__":
    unittest.main()
