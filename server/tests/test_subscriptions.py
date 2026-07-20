import asyncio
import base64
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from server import server_scheduler, server_storage, server_subscription


class SubscriptionRelay(
    server_storage.ServerStorageMixin,
    server_scheduler.ServerSchedulerMixin,
    server_subscription.ServerSubscriptionMixin,
):
    def __init__(self):
        self.revoked_devices = []
        self.clients = {}
        self.client_logins = {}
        self.routed_packets = []
        self.db = self.open_db()

    async def route_packet(self, packet):
        self.routed_packets.append(dict(packet))

    def wireguard_config_for(self, login, device_id):
        return (
            "[Interface]\n"
            f"# login={login}\n"
            f"# device={device_id}\n"
        )

    def revoke_wireguard_peers(
        self,
        login,
        product="meshpro",
        device_id=None,
    ):
        self.revoked_devices.append((login, product, device_id))
        return []


class SubscriptionTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.previous_db_path = server_storage.DB_PATH
        server_storage.DB_PATH = Path(self.temp_dir.name) / "server.db"
        self.relay = SubscriptionRelay()
        self.relay.db.execute(
            """
            INSERT INTO accounts(
                login,
                node_id,
                password_salt,
                password_hash,
                display_name
            )
            VALUES(
                'subscriber',
                'subscriber-node',
                'salt',
                'hash',
                'Subscriber'
            )
            """
        )
        self.relay.client_logins["subscriber-node"] = "subscriber"
        self.relay.db.commit()

    def tearDown(self):
        self.relay.db.close()
        server_storage.DB_PATH = self.previous_db_path
        self.temp_dir.cleanup()

    def test_vpn_config_requires_active_subscription(self):
        config, status, reason = self.relay.vpn_config_for(
            "subscriber",
            "device-a",
        )
        self.assertIsNone(config)
        self.assertFalse(status["active"])
        self.assertEqual("subscription_required", reason)

        granted = self.relay.grant_subscription("subscriber", days=7)
        self.assertTrue(granted["active"])
        config, status, reason = self.relay.vpn_config_for(
            "subscriber",
            "device-a",
        )
        self.assertIn("[Interface]", config)
        self.assertTrue(status["active"])
        self.assertEqual("ok", reason)

        revoked = self.relay.revoke_subscription("subscriber")
        self.assertFalse(revoked["active"])
        self.assertEqual("revoked", revoked["status"])

    def test_entitlements_only_unlock_available_features(self):
        inactive = self.relay.subscription_status("subscriber")
        inactive_entitlements = inactive["entitlements"]
        self.assertFalse(inactive_entitlements["active"])
        self.assertFalse(
            inactive_entitlements["features"]["meshprivacy_vpn"]
        )
        self.assertFalse(
            inactive_entitlements["features"]["ai_text_rewrite"]
        )

        active = self.relay.grant_subscription("subscriber", days=7)
        active_entitlements = active["entitlements"]
        self.assertTrue(active_entitlements["active"])
        self.assertTrue(
            active_entitlements["features"]["meshprivacy_vpn"]
        )
        self.assertTrue(
            active_entitlements["features"]["premium_badge"]
        )
        self.assertTrue(
            active_entitlements["features"]["profile_background"]
        )
        self.assertTrue(active_entitlements["features"]["profile_effect"])
        self.assertTrue(active_entitlements["features"]["profile_glow"])
        self.assertTrue(active_entitlements["features"]["custom_accent"])
        self.assertTrue(active_entitlements["features"]["ai_text_rewrite"])
        self.assertTrue(active_entitlements["features"]["animated_avatar"])
        self.assertTrue(active_entitlements["features"]["emoji_status"])
        self.assertTrue(active_entitlements["features"]["per_chat_theme"])
        self.assertTrue(
            active_entitlements["features"]["custom_message_bubbles"]
        )
        self.assertTrue(
            active_entitlements["features"]["animated_chat_backgrounds"]
        )
        self.assertTrue(active_entitlements["features"]["scheduled_messages"])
        self.assertTrue(
            active_entitlements["features"]["recurring_reminders"]
        )
        self.assertTrue(active_entitlements["features"]["story_hd"])
        self.assertTrue(
            active_entitlements["features"]["story_extended_video"]
        )
        self.assertTrue(
            active_entitlements["features"]["story_server_archive"]
        )
        self.assertTrue(
            active_entitlements["features"]["story_extra_reactions"]
        )
        self.assertTrue(
            active_entitlements["features"]["custom_quick_reactions"]
        )
        self.assertTrue(active_entitlements["features"]["call_hd_audio"])
        self.assertTrue(
            active_entitlements["features"]["call_noise_suppression_plus"]
        )
        self.assertTrue(
            active_entitlements["features"]["call_screen_share"]
        )
        self.assertTrue(
            active_entitlements["features"]["ai_message_translation"]
        )
        self.assertTrue(
            active_entitlements["features"]["multi_device_plus"]
        )
        self.assertTrue(
            self.relay.subscription_feature_enabled(
                "subscriber",
                "premium_badge",
            )
        )
        self.assertEqual(
            50,
            active_entitlements["limits"]["ai_text_rewrites_month"],
        )
        self.assertEqual(
            64 * 1024 * 1024,
            active_entitlements["limits"]["file_transfer_bytes"],
        )
        self.assertEqual(
            120,
            active_entitlements["limits"]["story_video_seconds"],
        )
        self.assertEqual(
            365,
            active_entitlements["limits"]["server_story_archive_days"],
        )
        self.assertEqual(
            200,
            active_entitlements["limits"]["scheduled_messages"],
        )
        self.assertEqual(
            150,
            active_entitlements["limits"]["ai_message_translations_month"],
        )

    def test_meshpro_preferences_and_device_revocation_are_server_backed(self):
        self.relay.save_account_device(
            "subscriber",
            "phone-node",
            "Subscriber",
            "1.0.0",
            True,
            "Android device",
        )
        ok, reason = self.relay.save_meshpro_preferences(
            "subscriber",
            ["heart", "ok"],
            True,
            True,
        )
        self.assertFalse(ok)
        self.assertEqual("meshpro_required", reason)

        self.relay.grant_subscription("subscriber", days=7)
        ok, reason = self.relay.save_meshpro_preferences(
            "subscriber",
            ["heart", "ok", "heart"],
            True,
            True,
        )
        self.assertTrue(ok)
        self.assertEqual("ok", reason)
        preferences = self.relay.get_meshpro_preferences("subscriber")
        self.assertEqual(["heart", "ok"], preferences["quick_reactions"])
        self.assertTrue(preferences["hd_audio"])
        self.assertTrue(preferences["enhanced_noise_suppression"])

        ok, reason = self.relay.update_account_device(
            "subscriber",
            "phone-node",
            "rename",
            "Travel phone",
        )
        self.assertTrue(ok)
        self.assertEqual("ok", reason)
        self.assertEqual(
            "Travel phone",
            self.relay.get_account_devices("subscriber")[0]["device_name"],
        )

        ok, reason = self.relay.update_account_device(
            "subscriber",
            "phone-node",
            "revoke",
        )
        self.assertTrue(ok)
        self.assertEqual("ok", reason)
        self.assertTrue(
            self.relay.is_account_device_revoked(
                "subscriber",
                "phone-node",
            )
        )
        self.assertEqual([], self.relay.get_online_account_nodes("subscriber"))

    def test_chat_appearance_and_emoji_status_are_server_gated(self):
        ok, reason = self.relay.save_chat_preferences(
            "subscriber",
            "direct:friend",
            "violet",
            "soft",
            True,
        )
        self.assertFalse(ok)
        self.assertEqual("meshpro_required", reason)

        ok, reason = self.relay.save_account_profile(
            "subscriber",
            "subscriber-node",
            "Subscriber",
            emoji_status="✨",
        )
        self.assertFalse(ok)
        self.assertEqual("meshpro_required", reason)

        self.relay.grant_subscription("subscriber", days=7)
        ok, reason = self.relay.save_chat_preferences(
            "subscriber",
            "direct:friend",
            "violet",
            "soft",
            True,
        )
        self.assertTrue(ok, reason)
        self.assertEqual(
            {
                "chat_key": "direct:friend",
                "theme_id": "violet",
                "bubble_style": "soft",
                "animated_background": True,
            },
            {
                key: value
                for key, value in self.relay.get_chat_preferences(
                    "subscriber"
                )[0].items()
                if key != "updated_at"
            },
        )

        ok, reason = self.relay.save_account_profile(
            "subscriber",
            "subscriber-node",
            "Subscriber",
            avatar_data="data:image/gif;base64,R0lGODlh",
            emoji_status="✨",
        )
        self.assertTrue(ok, reason)
        profile = self.relay.get_profile_by_node("subscriber-node")
        self.assertEqual("✨", profile["emoji_status"])
        self.assertTrue(profile["avatar_data"].startswith("data:image/gif"))

        oversized_avatar = base64.b64encode(
            b"x" * (server_storage.ANIMATED_AVATAR_MAX_BYTES + 1)
        ).decode("ascii")
        ok, reason = self.relay.save_account_profile(
            "subscriber",
            "subscriber-node",
            "Subscriber",
            avatar_data=f"data:image/gif;base64,{oversized_avatar}",
        )
        self.assertFalse(ok)
        self.assertEqual("animated avatar is too large", reason)

    def test_scheduled_message_dispatches_and_recurring_item_survives(self):
        self.relay.grant_subscription("subscriber", days=7)
        send_at = datetime.now(timezone.utc) + timedelta(minutes=5)
        packet = {
            "send_at": send_at.isoformat(),
            "repeat_interval": "none",
            "chat_key": "direct:friend",
            "preview": "Meet at seven",
            "payloads": [
                {
                    "type": "chat_message",
                    "source_node": "subscriber-node",
                    "destination_node": "friend-node",
                    "message": "encrypted-message",
                }
            ],
        }
        ok, reason, item = self.relay.create_scheduled_message(
            "subscriber-node",
            packet,
        )
        self.assertTrue(ok, reason)
        self.assertEqual("Meet at seven", item["preview"])
        self.assertEqual("Meet at seven", self.relay.list_scheduled_messages(
            "subscriber"
        )[0]["preview"])

        self.relay.db.execute(
            "UPDATE scheduled_messages SET next_run_at=DATETIME('now', '-1 second')"
        )
        self.relay.db.commit()
        dispatched = asyncio.run(
            self.relay.dispatch_due_scheduled_messages()
        )
        self.assertEqual(1, dispatched)
        self.assertEqual([], self.relay.list_scheduled_messages("subscriber"))
        self.assertEqual("encrypted-message", self.relay.routed_packets[0]["message"])
        stored = self.relay.db.execute(
            "SELECT message FROM direct_messages ORDER BY created_at DESC LIMIT 1"
        ).fetchone()
        self.assertEqual(("encrypted-message",), stored)

        recurring = dict(packet)
        recurring["preview"] = "Daily reminder"
        recurring["repeat_interval"] = "daily"
        ok, reason, recurring_item = self.relay.create_scheduled_message(
            "subscriber-node",
            recurring,
        )
        self.assertTrue(ok, reason)
        self.relay.db.execute(
            "UPDATE scheduled_messages SET next_run_at=DATETIME('now', '-1 second') "
            "WHERE schedule_id=?",
            (recurring_item["schedule_id"],),
        )
        self.relay.db.commit()
        asyncio.run(self.relay.dispatch_due_scheduled_messages())
        remaining = self.relay.list_scheduled_messages("subscriber")
        self.assertEqual(1, len(remaining))
        self.assertEqual("daily", remaining[0]["repeat_interval"])
        self.assertEqual(1, remaining[0]["run_count"])

    def test_story_quality_and_duration_are_enforced_on_the_server(self):
        too_long = self.relay.save_history_packet(
            {
                "type": "story_update",
                "packet_id": "free-too-long",
                "source_node": "subscriber-node",
                "destination_node": "SERVER",
                "story": {
                    "id": "free-too-long",
                    "owner_node": "subscriber-node",
                    "media_type": "video",
                    "video_duration_seconds": 31,
                },
            }
        )
        self.assertFalse(too_long)
        self.assertIsNone(
            self.relay.db.execute(
                "SELECT 1 FROM server_stories WHERE story_id='free-too-long'"
            ).fetchone()
        )

        self.relay.save_history_packet(
            {
                "type": "story_update",
                "packet_id": "free-hd",
                "source_node": "subscriber-node",
                "destination_node": "SERVER",
                "story": {
                    "id": "free-hd",
                    "owner_node": "subscriber-node",
                    "media_type": "video",
                    "video_duration_seconds": 20,
                    "hd": True,
                },
            }
        )
        stored_free = self.relay.db.execute(
            "SELECT story_json FROM server_stories WHERE story_id='free-hd'"
        ).fetchone()
        self.assertIn('"hd": false', stored_free[0])

        self.relay.grant_subscription("subscriber", days=7)
        accepted = self.relay.save_history_packet(
            {
                "type": "story_update",
                "packet_id": "pro-hd",
                "source_node": "subscriber-node",
                "destination_node": "SERVER",
                "story": {
                    "id": "pro-hd",
                    "owner_node": "subscriber-node",
                    "media_type": "video",
                    "video_duration_seconds": 90,
                    "hd": True,
                },
            }
        )
        self.assertIsNone(accepted)
        stored_pro = self.relay.db.execute(
            "SELECT story_json FROM server_stories WHERE story_id='pro-hd'"
        ).fetchone()
        self.assertIn('"hd": true', stored_pro[0])

    def test_catalog_is_versioned_and_returned_as_a_defensive_copy(self):
        first = self.relay.subscription_catalog("meshprivacy")
        self.assertEqual(1, first["schema_version"])
        self.assertEqual("meshpro", first["product"])
        self.assertIn("meshprivacy_vpn", first["features"])
        self.assertEqual(
            2 * 1024 * 1024 * 1024,
            first["limits"]["file_transfer_bytes"]["meshpro"],
        )

        first["features"].clear()
        second = self.relay.subscription_catalog("meshpro")
        self.assertIn("meshprivacy_vpn", second["features"])
        self.assertIsNone(self.relay.subscription_catalog("unknown"))

    def test_service_session_is_device_bound_and_revocable(self):
        token = self.relay.create_service_session(
            "subscriber",
            "meshprivacy",
            "device-a",
        )
        self.assertEqual(
            "subscriber",
            self.relay.authenticate_service_session(
                token,
                "meshprivacy",
                "device-a",
            ),
        )
        self.assertIsNone(
            self.relay.authenticate_service_session(
                token,
                "meshprivacy",
                "device-b",
            )
        )
        self.assertIsNone(
            self.relay.authenticate_service_session(
                token,
                "meshprivacy",
            )
        )

        self.relay.revoke_service_session(token, "meshprivacy")
        self.assertIsNone(
            self.relay.authenticate_service_session(
                token,
                "meshprivacy",
                "device-a",
            )
        )

    def test_expired_subscription_is_not_active(self):
        self.relay.grant_subscription("subscriber", days=1)
        self.relay.db.execute(
            """
            UPDATE account_subscriptions
            SET current_period_end=DATETIME('now', '-1 minute')
            WHERE login='subscriber' AND product='meshpro'
            """
        )
        self.relay.db.commit()
        status = self.relay.subscription_status("subscriber")
        self.assertFalse(status["active"])
        self.assertEqual("expired", status["status"])
        self.assertFalse(status["entitlements"]["active"])
        self.assertFalse(
            status["entitlements"]["features"]["meshprivacy_vpn"]
        )
        self.assertFalse(
            self.relay.subscription_feature_enabled(
                "subscriber",
                "premium_badge",
            )
        )

    def test_public_profile_badge_is_derived_from_subscription(self):
        self.relay.db.execute(
            """
            UPDATE accounts
            SET node_id='subscriber-node',
                public_username='subscriber'
            WHERE login='subscriber'
            """
        )
        self.relay.db.commit()

        inactive = self.relay.find_account_by_public_username("subscriber")
        self.assertFalse(inactive["meshpro_badge"])

        self.relay.grant_subscription("subscriber", days=7)
        active = self.relay.find_account_by_public_username("subscriber")
        self.assertTrue(active["meshpro_badge"])
        self.assertTrue(
            self.relay.get_profile_by_node("subscriber-node")[
                "meshpro_badge"
            ]
        )

        self.relay.revoke_subscription("subscriber")
        revoked = self.relay.find_account_by_public_username("subscriber")
        self.assertFalse(revoked["meshpro_badge"])

    def test_profile_style_is_server_gated_and_restored_after_renewal(self):
        self.relay.db.execute(
            """
            UPDATE accounts
            SET node_id='subscriber-node',
                public_username='subscriber'
            WHERE login='subscriber'
            """
        )
        self.relay.db.commit()

        ok, reason = self.relay.save_account_profile(
            "subscriber",
            "subscriber-node",
            "Subscriber",
            profile_background="aurora",
        )
        self.assertFalse(ok)
        self.assertEqual("meshpro_required", reason)

        self.relay.grant_subscription("subscriber", days=7)
        ok, reason = self.relay.save_account_profile(
            "subscriber",
            "subscriber-node",
            "Subscriber",
            profile_background="starlight",
            profile_effect="orbit",
            profile_blink_shape="moose",
            avatar_decoration="neon_orbit",
            profile_glow=True,
            profile_accent=0xFFA56BFF,
        )
        self.assertTrue(ok, reason)

        active = self.relay.find_account_by_public_username("subscriber")
        self.assertEqual("starlight", active["profile_background"])
        self.assertEqual("orbit", active["profile_effect"])
        self.assertEqual("moose", active["profile_blink_shape"])
        self.assertEqual("neon_orbit", active["avatar_decoration"])
        self.assertTrue(active["profile_glow"])
        self.assertEqual(0xFFA56BFF, active["profile_accent"])

        self.relay.revoke_subscription("subscriber")
        inactive = self.relay.get_profile_by_node("subscriber-node")
        self.assertEqual("mesh", inactive["profile_background"])
        self.assertEqual("nodes", inactive["profile_effect"])
        self.assertEqual("auto", inactive["profile_blink_shape"])
        self.assertEqual("none", inactive["avatar_decoration"])
        self.assertFalse(inactive["profile_glow"])
        self.assertEqual(0xFF42A5F5, inactive["profile_accent"])
        stored = self.relay.db.execute(
            """
            SELECT profile_background,
                   profile_effect,
                   profile_blink_shape,
                   avatar_decoration,
                   profile_glow,
                   profile_accent
            FROM accounts
            WHERE login='subscriber'
            """
        ).fetchone()
        self.assertEqual(
            (
                "starlight",
                "orbit",
                "moose",
                "neon_orbit",
                1,
                0xFFA56BFF,
            ),
            stored
        )

        self.relay.grant_subscription("subscriber", days=7)
        renewed = self.relay.get_profile_by_node("subscriber-node")
        self.assertEqual("starlight", renewed["profile_background"])
        self.assertEqual("orbit", renewed["profile_effect"])
        self.assertEqual("moose", renewed["profile_blink_shape"])
        self.assertEqual("neon_orbit", renewed["avatar_decoration"])
        self.assertTrue(renewed["profile_glow"])
        self.assertEqual(0xFFA56BFF, renewed["profile_accent"])

        ok, reason = self.relay.save_account_profile(
            "subscriber",
            "subscriber-node",
            "Subscriber",
            profile_blink_shape="sparkles",
        )
        self.assertTrue(ok, reason)
        normalized = self.relay.get_profile_by_node("subscriber-node")
        self.assertEqual("star", normalized["profile_blink_shape"])

        ok, reason = self.relay.save_account_profile(
            "subscriber",
            "subscriber-node",
            "Subscriber",
            profile_blink_shape="legacy-unknown-shape",
        )
        self.assertTrue(ok, reason)
        normalized = self.relay.get_profile_by_node("subscriber-node")
        self.assertEqual("dot", normalized["profile_blink_shape"])

        ok, reason = self.relay.save_account_profile(
            "subscriber",
            "subscriber-node",
            "Subscriber",
            profile_background="legacy-unknown-background",
            profile_effect="sparkles",
            avatar_decoration="ember_flame",
        )
        self.assertTrue(ok, reason)
        normalized = self.relay.get_profile_by_node("subscriber-node")
        self.assertEqual("mesh", normalized["profile_background"])
        self.assertEqual("stars", normalized["profile_effect"])
        self.assertEqual("ember", normalized["avatar_decoration"])

    def test_grant_extends_an_existing_period(self):
        first = self.relay.grant_subscription("subscriber", days=7)
        second = self.relay.grant_subscription("subscriber", days=7)
        first_end = self.relay._parse_subscription_time(
            first["current_period_end"]
        )
        second_end = self.relay._parse_subscription_time(
            second["current_period_end"]
        )
        self.assertIsNotNone(first_end)
        self.assertIsNotNone(second_end)
        self.assertGreater(second_end, first_end)

    def test_legacy_meshprivacy_entitlement_becomes_meshpro(self):
        self.relay.db.execute(
            """
            INSERT INTO account_subscriptions(
                login,
                product,
                plan_code,
                status,
                current_period_start,
                current_period_end,
                provider
            )
            VALUES(
                'subscriber',
                'meshprivacy',
                'monthly',
                'active',
                CURRENT_TIMESTAMP,
                DATETIME('now', '+14 days'),
                'manual'
            )
            """
        )
        self.relay.db.commit()

        status = self.relay.subscription_status("subscriber", "meshprivacy")

        self.assertTrue(status["active"])
        self.assertEqual("meshpro", status["product"])
        products = {
            row[0]
            for row in self.relay.db.execute(
                "SELECT product FROM account_subscriptions WHERE login='subscriber'"
            ).fetchall()
        }
        self.assertEqual({"meshpro"}, products)

    def test_revoking_meshpro_also_revokes_legacy_vpn_peers(self):
        self.relay.grant_subscription("subscriber", days=7)
        self.relay.revoke_subscription("subscriber")
        self.assertEqual(
            [("subscriber", "meshpro", None)],
            self.relay.revoked_devices,
        )


if __name__ == "__main__":
    unittest.main()
