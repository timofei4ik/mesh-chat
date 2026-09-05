import asyncio
import json
import unittest
import os
import uuid
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
from unittest.mock import patch

from server.reliable_sync import SyncDeliveryQueue, DeliveryCapacityError
from server.tests import test_sync_v2_contract as contract
from server.tests.test_sync_v2_contract import CapturingWebSocket
from server.tests import test_sync_integration as integration
from server.tests.test_realtime import FakeRedisBroker, FakeServer, FakeSocket
from server.server_realtime import RealtimeCoordinator
from server.runtime_metrics import RuntimeMetrics


class ReliableSyncTests(unittest.TestCase):
    setUp = contract.SyncV2ContractTests.setUp
    tearDown = contract.SyncV2ContractTests.tearDown
    register_device = contract.SyncV2ContractTests.register_device
    direct_mutation = contract.SyncV2ContractTests.direct_mutation

    def enable(self, capacity=100):
        self.queue = SyncDeliveryQueue(self.relay.db, max_accounts=capacity, retention_seconds=60)
        self.relay.sync_delivery_queue = self.queue
        self.register_device("alice", "alice-phone")
        self.register_device("bob", "bob-phone")

    def persist(self, packet, context=None):
        return self.relay.persist_history_mutation(packet, ["alice", "bob"], context)

    def test_queue_failure_rolls_back_history_journal_and_sender_ack_state(self):
        self.enable(capacity=1)
        packet, context = self.direct_mutation()
        with self.assertRaises(DeliveryCapacityError):
            self.persist(packet, context)
        self.assertEqual(1, self.relay.runtime_metrics.snapshot()["delivery_capacity_rejections_total"])
        for table in ("direct_messages", "sync_events", "processed_mutations", "realtime_sync_outbox"):
            self.assertEqual(0, self.relay.db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0])
        self.queue.max_accounts = 2
        self.persist(packet, context)
        self.assertGreater(self.queue.pending_cursor("bob", "bob-phone"), 0)
        self.assertTrue(self.relay.mutation_was_processed("alice", context["outbox_id"]))

    def test_compact_queue_and_restart_keep_latest_cursor(self):
        self.enable()
        for number in range(40):
            packet, _ = self.direct_mutation(str(number))
            self.persist(packet)
        self.assertEqual(2, self.queue.stats()["delivery_intent_accounts"])
        restarted = SyncDeliveryQueue(self.relay.db)
        target = self.relay.sync_v2_cursor("bob")
        self.assertEqual(target, restarted.pending_cursor("bob", "bob-phone"))
        self.relay.acknowledge_sync_v2_cursor("bob", "bob-phone", target)
        self.assertEqual(0, restarted.pending_cursor("bob", "bob-phone"))
        self.assertEqual(target, restarted.pending_cursor("bob", "bob-second-device"))

    def test_edits_and_deletes_restore_current_state_not_queued_copies(self):
        self.enable()
        packet, _ = self.direct_mutation("edited")
        self.persist(packet)
        baseline = self.relay.sync_v2_cursor("bob")
        self.persist({"type": "message_edit", "operation_id": "edit:edited", "message_id": "edited",
                      "source_node": "alice-phone", "destination_node": "bob-phone", "message": "new-ciphertext"})
        socket = CapturingWebSocket()
        asyncio.run(self.relay.send_account_sync(socket, "bob", "bob-phone", supports_sync_v2=True))
        encoded = json.dumps(socket.sent)
        self.assertIn("new-ciphertext", encoded)
        self.assertNotIn("ciphertext:edited", encoded)
        self.persist({"type": "message_delete", "operation_id": "delete:edited", "message_id": "edited",
                      "source_node": "alice-phone", "destination_node": "bob-phone"})
        plan = self.relay.plan_sync_v2_delivery("bob", baseline, supports_delta=True)
        self.assertEqual(["message_edit", "message_delete"], [e["packet_type"] for e in plan["events"]])
        self.assertTrue(plan["events"][-1]["tombstone"])
        socket = CapturingWebSocket()
        asyncio.run(self.relay.send_account_sync(socket, "bob", "bob-phone", supports_sync_v2=True))
        self.assertNotIn("new-ciphertext", json.dumps(socket.sent))

    def test_expiry_is_bounded_and_offline_device_can_still_recover(self):
        self.enable()
        with patch("server.reliable_sync.time.time", return_value=100):
            packet, _ = self.direct_mutation("retained-history")
            self.persist(packet)
        with patch("server.reliable_sync.time.time", return_value=1000):
            with self.relay.atomic_storage_transaction():
                self.assertEqual(1, self.queue.prune(limit=1))
            with self.relay.atomic_storage_transaction():
                self.queue.prune()
        self.assertEqual(0, self.queue.stats()["delivery_intent_accounts"])
        self.assertGreater(self.queue.pending_cursor("bob", "bob-phone"), 0)
        self.assertEqual(1, self.relay.db.execute("SELECT COUNT(*) FROM direct_messages").fetchone()[0])

    def test_stage_without_transaction_is_rejected(self):
        self.enable()
        with self.assertRaises(RuntimeError):
            self.queue.stage("alice", 1)

    def test_newer_write_cannot_be_replaced_by_older_cursor(self):
        self.enable()
        with self.relay.atomic_storage_transaction():
            self.queue.stage("alice", 20)
            self.queue.stage("alice", 10)
        self.assertEqual(20, self.relay.db.execute("SELECT target_cursor FROM realtime_sync_outbox").fetchone()[0])


class ReliableSyncSocketTests(unittest.IsolatedAsyncioTestCase):
    asyncSetUp = integration.ServerSyncIntegrationTests.asyncSetUp
    asyncTearDown = integration.ServerSyncIntegrationTests.asyncTearDown
    _close_relay_runtime = integration.ServerSyncIntegrationTests._close_relay_runtime

    async def test_delayed_recovery_uses_hint_without_stale_payload(self):
        self.relay.sync_delivery_queue = SyncDeliveryQueue(self.relay.db)
        async def connect(login, reliable=False):
            client = integration.TestClient(self.uri, login, "test-password", login + "-phone",
                supports_sync_v2=True, supports_reliable_sync_v2=reliable)
            self.clients.append(client)
            await client.connect()
            return client
        alice = await connect("alice")
        bob = await connect("bob", True)
        await alice.send({"type": "chat_message", "packet_id": "wire-message",
            "operation_id": "wire-message", "source_node": "alice-phone",
            "destination_node": "bob-phone", "message": "original"})
        hint = await bob.receive_type("reliable_sync_hint")
        self.assertNotIn("message", hint)
        await alice.send({"type": "message_edit", "operation_id": "wire-edit",
            "message_id": "wire-message", "source_node": "alice-phone",
            "destination_node": "bob-phone", "message": "edited"})
        await bob.receive_type("reliable_sync_hint")
        # The receiver requests recovery only after the edit: no queued old body.
        await bob.send({"type": "reliable_sync_request", "cursor": 0})
        snapshot = await bob.receive_type("server_sync")
        done = await bob.receive_type("server_sync_done")
        self.assertIn("edited", json.dumps(snapshot))
        self.assertNotIn('"original"', json.dumps(snapshot))
        await bob.send({"type": "sync_v2_ack", "cursor": done["sync_cursor"]})
        for _ in range(30):
            if self.relay.sync_delivery_queue.pending_cursor("bob", "bob-phone") == 0:
                break
            await asyncio.sleep(.01)
        self.assertEqual(0, self.relay.sync_delivery_queue.pending_cursor("bob", "bob-phone"))
        self.assertNotEqual(0, self.relay.sync_delivery_queue.pending_cursor("bob", "bob-other-device"))

    async def test_lost_redis_wakeup_does_not_replay_payload_through_legacy_queue(self):
        broker = FakeRedisBroker()
        def worker(name):
            server = FakeServer()
            server.client_logins = {"bob-phone": "bob"}
            server.runtime_metrics = RuntimeMetrics()
            server.sync_delivery_queue = SimpleNamespace(pending_cursor=lambda login, node: 42)
            coordinator = RealtimeCoordinator(server, redis_url="redis://test", worker_id=name)
            coordinator.redis = broker.client()
            return coordinator
        source, target = worker("a"), worker("b")
        socket = FakeSocket()
        target.server.clients["bob-phone"] = socket
        target.server.client_capabilities["bob-phone"] = {"reliable_sync_v2": True}
        await target.register("bob-phone", login="bob", capabilities={"reliable_sync_v2": True})
        accepted = await source.send_to_node("bob-phone", {
            "type": "message_edit", "message": "must not replay", "message_id": "one",
        })
        self.assertTrue(accepted)
        self.assertEqual([], socket.sent)
        await target._send_sync_hint("bob-phone", socket)
        self.assertEqual([{"type": "reliable_sync_hint", "cursor": 42}], socket.sent)


@unittest.skipUnless(os.environ.get("MESH_TEST_DATABASE_URL"), "Local test PostgreSQL required")
class PostgresReliableSyncTests(unittest.TestCase):
    def test_transactions_and_cross_worker_capacity_limit(self):
        from psycopg import sql
        from server.ops.reliability_lab.queue_probe import validate_url
        from server.persistence.postgres import connect_postgres, PostgresCompatibilityConnection
        url = os.environ["MESH_TEST_DATABASE_URL"]
        validate_url(url)
        a = PostgresCompatibilityConnection(connect_postgres(url))
        b = PostgresCompatibilityConnection(connect_postgres(url))
        schema = "sync_lab_" + uuid.uuid4().hex
        identifier = sql.Identifier(schema)
        try:
            a.raw_connection.execute(sql.SQL("CREATE SCHEMA {}").format(identifier))
            for connection in (a, b):
                connection.raw_connection.execute(sql.SQL("SET search_path TO {}").format(identifier))
            first, second = SyncDeliveryQueue(a, max_accounts=1), SyncDeliveryQueue(b, max_accounts=1)
            a.execute("CREATE TABLE history_test(id INTEGER PRIMARY KEY)")
            with self.assertRaisesRegex(RuntimeError, "injected"):
                with a.transaction():
                    a.execute("INSERT INTO history_test VALUES(1)")
                    first.stage("alice", 1)
                    raise RuntimeError("injected crash before commit")
            self.assertEqual(0, first.stats()["delivery_intent_accounts"])
            self.assertEqual(0, a.execute("SELECT COUNT(*) FROM history_test").fetchone()[0])

            def stage(args):
                queue, login = args
                try:
                    with queue.db.transaction():
                        queue.stage(login, 5)
                    return True
                except DeliveryCapacityError:
                    return False
            with ThreadPoolExecutor(max_workers=2) as pool:
                results = list(pool.map(stage, [(first, "alice"), (second, "bob")]))
            self.assertEqual(1, sum(results))
            self.assertEqual(1, first.stats()["delivery_intent_accounts"])
        finally:
            a.raw_connection.execute(sql.SQL("DROP SCHEMA {} CASCADE").format(identifier))
            a.close()
            b.close()
