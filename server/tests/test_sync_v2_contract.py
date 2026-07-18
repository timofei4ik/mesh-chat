import asyncio
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from server import server as server_module
from server import server_auth, server_storage, server_sync
from server.sync_v2_shadow import (
    DELTA_SHADOW_EVENT_TYPES,
    compare_sync_v2_shadow,
)


class CapturingWebSocket:
    def __init__(self, fail_after=None):
        self.fail_after = fail_after
        self.sent = []

    async def send(self, raw):
        if self.fail_after is not None and len(self.sent) >= self.fail_after:
            raise ConnectionError("injected sync interruption")
        self.sent.append(json.loads(raw))


class SyncV2ContractTests(unittest.TestCase):
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

    def register_device(self, login, node_id):
        ok, _ = self.relay.authenticate_account(
            login,
            "test-password",
            node_id,
            login.title(),
            public_username=login,
            encryption_public_key=f"public-key:{node_id}",
        )
        self.assertTrue(ok)
        self.relay.save_account_device(
            login,
            node_id,
            login.title(),
            "contract-test",
            True,
            node_id,
        )

    def record_message_event(self, login, message_id):
        return self.relay.record_sync_v2_event(
            {
                "type": "chat_message",
                "packet_id": message_id,
                "operation_id": f"chat_message:{message_id}",
                "source_node": f"{login}-phone",
                "destination_node": "peer-phone",
                "message": f"ciphertext:{message_id}",
            },
            [login],
        )

    def direct_mutation(self, message_id="atomic-message"):
        operation_id = f"chat_message:{message_id}"
        return (
            {
                "type": "chat_message",
                "packet_id": message_id,
                "operation_id": operation_id,
                "outbox_id": f"outbox:{message_id}",
                "source_node": "alice-phone",
                "destination_node": "bob-phone",
                "sender": "Alice",
                "message": f"ciphertext:{message_id}",
            },
            {
                "account_login": "alice",
                "outbox_id": f"outbox:{message_id}",
                "operation_id": operation_id,
            },
        )

    def persist_packet(self, packet, account_logins=("alice", "bob")):
        result = self.relay.persist_history_mutation(
            packet,
            account_logins,
        )
        self.assertIsNot(result["saved"], False)
        return result["saved"]

    def assert_mutation_absent(self, message_id, operation_id, outbox_id):
        self.assertEqual(
            0,
            self.relay.db.execute(
                "SELECT COUNT(*) FROM direct_messages WHERE message_id=?",
                (message_id,),
            ).fetchone()[0],
        )
        self.assertEqual(
            0,
            self.relay.db.execute(
                "SELECT COUNT(*) FROM sync_events WHERE operation_id=?",
                (operation_id,),
            ).fetchone()[0],
        )
        self.assertEqual(
            0,
            self.relay.db.execute(
                "SELECT COUNT(*) FROM processed_mutations WHERE outbox_id=?",
                (outbox_id,),
            ).fetchone()[0],
        )
        self.assertFalse(self.relay.db.in_transaction)

    def test_event_stream_is_ordered_and_operation_is_deduplicated(self):
        self.record_message_event("alice", "message-a")
        self.record_message_event("alice", "message-a")
        self.record_message_event("alice", "message-b")

        events = self.relay.list_sync_v2_events("alice", 0)

        self.assertEqual(2, len(events))
        self.assertEqual(
            ["chat_message:message-a", "chat_message:message-b"],
            [event["operation_id"] for event in events],
        )
        self.assertEqual(
            sorted(event["event_id"] for event in events),
            [event["event_id"] for event in events],
        )
        self.assertTrue(
            all(event["event_id"] == event["cursor"] for event in events)
        )

    def test_every_delta_safe_event_has_a_shadow_reducer(self):
        self.assertEqual(
            server_sync.SYNC_V2_EVENT_PACKET_TYPES
            - server_sync.SYNC_V2_SNAPSHOT_ONLY_PACKET_TYPES,
            DELTA_SHADOW_EVENT_TYPES,
        )

    def test_delta_can_be_enabled_for_canary_accounts_only(self):
        with mock.patch.object(
            server_module,
            "SYNC_V2_DELTA_ENABLED",
            False,
        ), mock.patch.object(
            server_module,
            "SYNC_V2_DELTA_TEST_ACCOUNTS",
            frozenset({"alice"}),
        ):
            self.assertTrue(self.relay.sync_v2_delta_enabled_for("Alice"))
            self.assertFalse(self.relay.sync_v2_delta_enabled_for("bob"))

    def test_cursor_ack_is_per_device_monotonic_and_rejects_future(self):
        self.record_message_event("alice", "message-a")
        self.record_message_event("alice", "message-b")
        current = self.relay.sync_v2_cursor("alice")

        self.assertTrue(
            self.relay.acknowledge_sync_v2_cursor(
                "alice", "alice-phone", current
            )
        )
        self.assertTrue(
            self.relay.acknowledge_sync_v2_cursor(
                "alice", "alice-phone", current - 1
            )
        )
        self.assertTrue(
            self.relay.acknowledge_sync_v2_cursor(
                "alice", "alice-desktop", current - 1
            )
        )
        self.assertFalse(
            self.relay.acknowledge_sync_v2_cursor(
                "alice", "alice-phone", current + 1
            )
        )

        rows = self.relay.db.execute(
            """
            SELECT node_id, cursor
            FROM sync_cursors
            WHERE account_login='alice'
            ORDER BY node_id
            """
        ).fetchall()
        self.assertEqual(
            [
                ("alice-desktop", current - 1),
                ("alice-phone", current),
            ],
            rows,
        )

    def test_delete_events_are_explicit_tombstones(self):
        self.relay.record_sync_v2_event(
            {
                "type": "message_delete",
                "packet_id": "delete-packet",
                "operation_id": "message_delete:message-a",
                "source_node": "alice-phone",
                "destination_node": "bob-phone",
                "message_id": "message-a",
            },
            ["alice", "bob"],
        )

        for login in ("alice", "bob"):
            events = self.relay.list_sync_v2_events(login, 0)
            self.assertEqual(1, len(events))
            self.assertTrue(events[0]["tombstone"])
            self.assertFalse(events[0]["requires_snapshot"])
            self.assertEqual("message-a", events[0]["payload"]["message_id"])

    def test_binary_event_requires_authoritative_snapshot(self):
        self.relay.record_sync_v2_event(
            {
                "type": "profile_update",
                "packet_id": "profile-avatar-update",
                "operation_id": "profile_update:profile-avatar-update",
                "source_node": "alice-phone",
                "login": "alice",
                "display_name": "Alice",
                "avatar_data": "large-binary-body",
            },
            ["alice"],
        )

        event = self.relay.list_sync_v2_events("alice", 0)[0]
        self.assertTrue(event["requires_snapshot"])
        self.assertNotIn("avatar_data", event["payload"])

    def test_same_account_devices_create_one_group_member(self):
        self.register_device("alice", "alice-phone")
        self.register_device("alice", "alice-desktop")

        self.relay.save_group_members(
            "group-a",
            "Group A",
            ["alice-phone", "alice-desktop"],
            owner_node="alice-phone",
            admins=[],
        )

        members = self.relay.db.execute(
            """
            SELECT node_id, login
            FROM server_group_members
            WHERE group_id='group-a'
            """
        ).fetchall()
        self.assertEqual(1, len(members))
        self.assertEqual("alice", members[0][1])

    def test_same_account_devices_create_one_identical_reaction(self):
        self.register_device("alice", "alice-phone")
        self.register_device("alice", "alice-desktop")

        for node_id in ("alice-phone", "alice-desktop", "alice-phone"):
            self.relay.save_history_packet(
                {
                    "type": "message_reaction",
                    "packet_id": f"reaction:{node_id}",
                    "source_node": node_id,
                    "destination_node": "bob-phone",
                    "message_id": "message-a",
                    "reaction": "heart",
                }
            )

        rows = self.relay.db.execute(
            """
            SELECT reactor_login, reactor_identity, reaction
            FROM server_reactions
            WHERE scope='direct' AND message_id='message-a'
            """
        ).fetchall()
        self.assertEqual([("alice", "login:alice", "heart")], rows)

    def test_atomic_mutation_rolls_back_when_event_journal_fails(self):
        self.register_device("alice", "alice-phone")
        self.register_device("bob", "bob-phone")
        packet, context = self.direct_mutation("event-failure")

        with mock.patch.object(
            self.relay,
            "record_sync_v2_event",
            side_effect=RuntimeError("injected event journal failure"),
        ):
            with self.assertRaisesRegex(RuntimeError, "event journal failure"):
                self.relay.persist_history_mutation(
                    packet,
                    ["alice", "bob"],
                    context,
                )

        self.assert_mutation_absent(
            packet["packet_id"],
            packet["operation_id"],
            context["outbox_id"],
        )

        result = self.relay.persist_history_mutation(
            packet,
            ["alice", "bob"],
            context,
        )
        self.assertIsNot(result["saved"], False)
        self.assertTrue(result["processed_inserted"])
        self.assertEqual(
            1,
            self.relay.db.execute(
                "SELECT COUNT(*) FROM direct_messages WHERE message_id=?",
                (packet["packet_id"],),
            ).fetchone()[0],
        )
        self.assertEqual(
            2,
            self.relay.db.execute(
                "SELECT COUNT(*) FROM sync_events WHERE operation_id=?",
                (packet["operation_id"],),
            ).fetchone()[0],
        )
        self.assertEqual(
            1,
            self.relay.db.execute(
                "SELECT COUNT(*) FROM processed_mutations WHERE outbox_id=?",
                (context["outbox_id"],),
            ).fetchone()[0],
        )

    def test_atomic_mutation_rolls_back_when_processed_marker_fails(self):
        self.register_device("alice", "alice-phone")
        self.register_device("bob", "bob-phone")
        packet, context = self.direct_mutation("marker-failure")

        with mock.patch.object(
            self.relay,
            "mark_mutation_processed",
            side_effect=RuntimeError("injected processed marker failure"),
        ):
            with self.assertRaisesRegex(RuntimeError, "processed marker failure"):
                self.relay.persist_history_mutation(
                    packet,
                    ["alice", "bob"],
                    context,
                )

        self.assert_mutation_absent(
            packet["packet_id"],
            packet["operation_id"],
            context["outbox_id"],
        )

    def test_safe_delta_plan_is_bounded_by_captured_target(self):
        first = self.record_message_event("alice", "message-a")["alice"]
        self.record_message_event("alice", "message-b")
        target = self.record_message_event("alice", "message-c")["alice"]

        plan = self.relay.plan_sync_v2_delivery(
            "alice",
            first,
            supports_delta=True,
        )

        self.assertEqual("delta", plan["mode"])
        self.assertEqual(first, plan["source_cursor"])
        self.assertEqual(target, plan["target_cursor"])
        self.assertEqual(
            ["chat_message:message-b", "chat_message:message-c"],
            [event["operation_id"] for event in plan["events"]],
        )

    def test_unsafe_and_pruned_ranges_force_snapshot(self):
        first = self.record_message_event("alice", "message-a")["alice"]
        unsafe = self.relay.record_sync_v2_event(
            {
                "type": "profile_update",
                "packet_id": "profile-a",
                "operation_id": "profile_update:profile-a",
                "source_node": "alice-phone",
                "login": "alice",
                "display_name": "Alice 2",
            },
            ["alice"],
        )["alice"]

        unsafe_plan = self.relay.plan_sync_v2_delivery(
            "alice",
            first,
            supports_delta=True,
        )
        self.assertEqual("snapshot", unsafe_plan["mode"])
        self.assertEqual("unsafe_event", unsafe_plan["reason"])

        self.assertEqual(unsafe, self.relay.prune_sync_v2_events("alice", unsafe))
        self.assertEqual(unsafe, self.relay.sync_v2_cursor("alice"))
        self.assertEqual([], self.relay.list_sync_v2_events("alice", 0))
        pruned_plan = self.relay.plan_sync_v2_delivery(
            "alice",
            first,
            supports_delta=True,
        )
        self.assertEqual("snapshot", pruned_plan["mode"])
        self.assertEqual("pruned_cursor", pruned_plan["reason"])

    def test_event_after_snapshot_boundary_is_available_in_next_delta(self):
        boundary = self.record_message_event("alice", "before-snapshot")[
            "alice"
        ]
        snapshot = self.relay.build_sync_packet("alice", "alice-phone")
        after = self.record_message_event("alice", "after-snapshot")["alice"]

        self.assertEqual("server_sync", snapshot["type"])
        plan = self.relay.plan_sync_v2_delivery(
            "alice",
            boundary,
            supports_delta=True,
        )
        self.assertEqual("delta", plan["mode"])
        self.assertEqual(after, plan["target_cursor"])
        self.assertEqual(
            ["chat_message:after-snapshot"],
            [event["operation_id"] for event in plan["events"]],
        )

    def test_interrupted_delta_replays_same_range_without_cursor_ack(self):
        source = self.record_message_event("alice", "message-a")["alice"]
        self.record_message_event("alice", "message-b")
        target = self.record_message_event("alice", "message-c")["alice"]
        interrupted = CapturingWebSocket(fail_after=2)

        with self.assertRaisesRegex(ConnectionError, "sync interruption"):
            asyncio.run(
                self.relay.send_account_sync(
                    interrupted,
                    "alice",
                    "alice-phone",
                    supports_sync_v2=True,
                    supports_sync_v2_delta=True,
                    requested_sync_cursor=source,
                )
            )

        self.assertIsNone(
            self.relay.db.execute(
                """
                SELECT cursor
                FROM sync_cursors
                WHERE account_login='alice' AND node_id='alice-phone'
                """
            ).fetchone()
        )

        replay = CapturingWebSocket()
        asyncio.run(
            self.relay.send_account_sync(
                replay,
                "alice",
                "alice-phone",
                supports_sync_v2=True,
                supports_sync_v2_delta=True,
                requested_sync_cursor=source,
            )
        )
        self.assertEqual(
            [
                "server_sync_delta_begin",
                "server_sync_delta_event",
                "server_sync_delta_event",
                "server_sync_done",
            ],
            [packet["type"] for packet in replay.sent],
        )
        self.assertEqual(target, replay.sent[-1]["sync_cursor"])

    def test_delta_shadow_matches_fresh_snapshot_for_core_mutations(self):
        self.register_device("alice", "alice-phone")
        self.register_device("bob", "bob-phone")
        self.persist_packet(
            {
                "type": "chat_message",
                "packet_id": "shadow-old",
                "source_node": "alice-phone",
                "destination_node": "bob-phone",
                "sender": "Alice",
                "message": "ciphertext:old",
            }
        )
        source_cursor = self.relay.sync_v2_cursor("alice")
        source_snapshot = self.relay.build_sync_packet(
            "alice",
            "alice-phone",
        )

        self.persist_packet(
            {
                "type": "chat_message",
                "packet_id": "shadow-new",
                "source_node": "alice-phone",
                "destination_node": "bob-phone",
                "sender": "Alice",
                "message": "ciphertext:new",
                "reply_to_message_id": "shadow-old",
                "reply_to_text": "old",
                "message_effect": "none",
            }
        )
        self.persist_packet(
            {
                "type": "message_edit",
                "packet_id": "shadow-edit",
                "message_id": "shadow-new",
                "source_node": "alice-phone",
                "destination_node": "bob-phone",
                "message": "ciphertext:edited",
            }
        )
        self.persist_packet(
            {
                "type": "message_reaction",
                "packet_id": "shadow-reaction",
                "message_id": "shadow-new",
                "source_node": "bob-phone",
                "destination_node": "alice-phone",
                "reaction": "heart",
            }
        )
        self.persist_packet(
            {
                "type": "message_pin",
                "packet_id": "shadow-pin",
                "message_id": "shadow-new",
                "source_node": "alice-phone",
                "destination_node": "bob-phone",
                "text": "ciphertext:edited",
            }
        )
        self.persist_packet(
            {
                "type": "message_delete",
                "packet_id": "shadow-delete-old",
                "message_id": "shadow-old",
                "source_node": "alice-phone",
                "destination_node": "bob-phone",
            }
        )
        self.persist_packet(
            {
                "type": "group_update",
                "packet_id": "shadow-group-create",
                "group_id": "shadow-group",
                "group_name": "Shadow group",
                "members": ["alice-phone", "bob-phone"],
                "owner_node": "alice-phone",
                "admins": ["alice-phone"],
                "source_node": "alice-phone",
                "destination_node": "bob-phone",
                "comments_enabled": True,
            }
        )
        self.persist_packet(
            {
                "type": "group_message",
                "packet_id": "shadow-group-message",
                "group_message_id": "shadow-group-message",
                "group_id": "shadow-group",
                "group_name": "Shadow group",
                "members": ["alice-phone", "bob-phone"],
                "source_node": "alice-phone",
                "destination_node": "bob-phone",
                "sender": "Alice",
                "message": "ciphertext:group",
                "group_key_id": "key-1",
            }
        )
        self.persist_packet(
            {
                "type": "group_message_edit",
                "packet_id": "shadow-group-edit",
                "group_message_id": "shadow-group-message",
                "group_id": "shadow-group",
                "source_node": "alice-phone",
                "destination_node": "bob-phone",
                "message": "ciphertext:group-edited",
                "group_key_id": "key-2",
            }
        )
        self.persist_packet(
            {
                "type": "group_reaction",
                "packet_id": "shadow-group-reaction",
                "group_message_id": "shadow-group-message",
                "group_id": "shadow-group",
                "source_node": "bob-phone",
                "destination_node": "alice-phone",
                "reaction": "heart",
            }
        )
        self.persist_packet(
            {
                "type": "group_pin",
                "packet_id": "shadow-group-pin",
                "message_id": "shadow-group-message",
                "group_id": "shadow-group",
                "source_node": "alice-phone",
                "destination_node": "bob-phone",
                "text": "ciphertext:group-edited",
                "group_key_id": "key-2",
            }
        )

        plan = self.relay.plan_sync_v2_delivery(
            "alice",
            source_cursor,
            supports_delta=True,
        )
        target_snapshot = self.relay.build_sync_packet(
            "alice",
            "alice-phone",
        )
        report = compare_sync_v2_shadow(
            source_snapshot,
            plan["events"],
            target_snapshot,
            node_id="alice-phone",
        )

        self.assertEqual("delta", plan["mode"])
        self.assertTrue(report["ok"], report["mismatches"])

    def test_file_and_sticker_changes_force_snapshot_instead_of_empty_delta(self):
        self.register_device("alice", "alice-phone")
        self.register_device("bob", "bob-phone")
        source = self.record_message_event("alice", "before-file")["alice"]
        first_chunk = {
            "type": "file_chunk",
            "packet_id": "file-event-1:0",
            "file_id": "file-event-1",
            "filename": "file.bin",
            "chunk_index": 0,
            "total_chunks": 2,
            "data": "aa",
            "source_node": "alice-phone",
            "destination_node": "bob-phone",
        }
        self.assertEqual(
            "pending",
            self.persist_packet(first_chunk),
        )
        self.assertEqual(source, self.relay.sync_v2_cursor("alice"))
        final_chunk = {
            **first_chunk,
            "packet_id": "file-event-1:1",
            "chunk_index": 1,
            "data": "bb",
        }
        self.assertTrue(self.persist_packet(final_chunk))
        file_plan = self.relay.plan_sync_v2_delivery(
            "alice",
            source,
            supports_delta=True,
        )
        self.assertEqual("snapshot", file_plan["mode"])
        self.assertEqual("unsafe_event", file_plan["reason"])

        sticker_source = self.relay.sync_v2_cursor("alice")
        self.assertTrue(
            self.persist_packet(
                {
                    "type": "sticker_library_update",
                    "packet_id": "sticker-library-event",
                    "source_node": "alice-phone",
                    "destination_node": "SERVER",
                    "login": "alice",
                    "sticker_library": {
                        "packs": [],
                        "favorite_ids": [],
                    },
                },
                ("alice",),
            )
        )
        sticker_plan = self.relay.plan_sync_v2_delivery(
            "alice",
            sticker_source,
            supports_delta=True,
        )
        self.assertEqual("snapshot", sticker_plan["mode"])
        self.assertEqual("unsafe_event", sticker_plan["reason"])

    def test_two_device_delta_soak_matches_snapshot_after_replays(self):
        self.register_device("alice", "alice-phone")
        self.register_device("alice", "alice-desktop")
        self.register_device("bob", "bob-phone")
        self.persist_packet(
            {
                "type": "chat_message",
                "packet_id": "soak-seed",
                "source_node": "alice-phone",
                "destination_node": "bob-phone",
                "sender": "Alice",
                "message": "ciphertext:seed",
            }
        )

        device_states = {
            "alice-phone": {
                "cursor": self.relay.sync_v2_cursor("alice"),
                "snapshot": self.relay.build_sync_packet(
                    "alice",
                    "alice-phone",
                ),
            },
            "alice-desktop": {
                "cursor": self.relay.sync_v2_cursor("alice"),
                "snapshot": self.relay.build_sync_packet(
                    "alice",
                    "alice-desktop",
                ),
            },
        }
        live_ids = ["soak-seed"]

        def sync_device(node_id):
            device = device_states[node_id]
            plan = self.relay.plan_sync_v2_delivery(
                "alice",
                device["cursor"],
                supports_delta=True,
            )
            target = self.relay.build_sync_packet("alice", node_id)
            report = compare_sync_v2_shadow(
                device["snapshot"],
                plan["events"],
                target,
                node_id=node_id,
            )
            self.assertEqual("delta", plan["mode"])
            self.assertTrue(report["ok"], report["mismatches"])
            device["cursor"] = plan["target_cursor"]
            device["snapshot"] = target

        for index in range(240):
            source_node = (
                "alice-phone" if index % 2 == 0 else "alice-desktop"
            )
            message_id = f"soak-message-{index:03d}"
            packet = {
                "type": "chat_message",
                "packet_id": message_id,
                "source_node": source_node,
                "destination_node": "bob-phone",
                "sender": "Alice",
                "message": f"ciphertext:{index}",
            }
            self.persist_packet(packet)
            if index % 11 == 0:
                self.assertIsNot(self.persist_packet(packet), False)
            live_ids.append(message_id)

            if index % 5 == 0:
                self.persist_packet(
                    {
                        "type": "message_edit",
                        "packet_id": f"soak-edit-{index:03d}",
                        "message_id": message_id,
                        "source_node": source_node,
                        "destination_node": "bob-phone",
                        "message": f"ciphertext:edited:{index}",
                    }
                )
            if index % 7 == 0:
                reaction_packet = {
                    "type": "message_reaction",
                    "packet_id": f"soak-reaction-{index:03d}",
                    "message_id": message_id,
                    "source_node": source_node,
                    "destination_node": "bob-phone",
                    "reaction": "heart",
                }
                self.persist_packet(reaction_packet)
                duplicate_reaction = {
                    **reaction_packet,
                    "packet_id": f"soak-reaction-duplicate-{index:03d}",
                    "source_node": (
                        "alice-desktop"
                        if source_node == "alice-phone"
                        else "alice-phone"
                    ),
                }
                self.assertEqual(
                    "duplicate",
                    self.persist_packet(duplicate_reaction),
                )
            if index % 9 == 0 and len(live_ids) > 8:
                deleted_id = live_ids.pop(0)
                self.persist_packet(
                    {
                        "type": "message_delete",
                        "packet_id": f"soak-delete-{index:03d}",
                        "message_id": deleted_id,
                        "source_node": source_node,
                        "destination_node": "bob-phone",
                    }
                )

            if index % 7 == 0:
                sync_device("alice-phone")
            if index % 19 == 0:
                sync_device("alice-desktop")

        sync_device("alice-phone")
        sync_device("alice-desktop")
        self.assertEqual(
            device_states["alice-phone"]["cursor"],
            device_states["alice-desktop"]["cursor"],
        )


if __name__ == "__main__":
    unittest.main()
