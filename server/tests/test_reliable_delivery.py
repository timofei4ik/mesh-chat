import json
import os
import sqlite3
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from urllib.parse import urlparse

from server.reliable_delivery import DeliveryOutbox, DeliveryDeletionOwner
from server.runtime_metrics import RuntimeMetrics
from server.server_commands_sync import handle_reliable_delivery_ack
from server.server_realtime import RealtimeCoordinator
from server.tests.test_realtime import FakeRedisBroker, FakeServer, FakeSocket


class DeliveryStoreTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name) / "delivery.db"
        self.db = sqlite3.connect(self.path)
        self.addCleanup(self.directory.cleanup)
        self.addCleanup(lambda: self.db.close())
        self.outbox = DeliveryOutbox(self.db)

    def test_reopen_retry_claim_and_bound_ack(self):
        packet = {"type": "chat_message", "message_id": "one", "text": "test"}
        delivery = self.outbox.enqueue("phone", "bob", packet)
        self.assertEqual(delivery, self.outbox.enqueue("phone", "bob", packet, None))
        self.assertTrue(self.outbox.claim(delivery))
        self.assertFalse(self.outbox.claim(delivery))
        self.db.close()
        self.db = sqlite3.connect(self.path)
        self.outbox = DeliveryOutbox(self.db)
        self.assertEqual(1, self.outbox.stats()["delivery_queue_depth"])
        self.assertIsNone(self.outbox.acknowledge("other-phone", "bob", delivery))
        self.assertIsNone(self.outbox.acknowledge("phone", "alice", delivery))
        with patch("server.reliable_delivery.time.time", return_value=9999999999):
            self.assertEqual(delivery, self.outbox.pending("phone", "bob")[0][0])
            self.assertTrue(self.outbox.claim(delivery))
        self.assertIsNotNone(self.outbox.acknowledge("phone", "bob", delivery))
        self.assertEqual(0, self.outbox.stats()["delivery_queue_depth"])

    def test_account_deletion_removes_received_and_authored_packets(self):
        self.outbox.enqueue("phone", "bob", {"type": "chat_message", "sender_login": "alice"})
        self.outbox.enqueue("phone2", "alice", {"type": "chat_message", "sender_login": "bob"})
        owner = DeliveryDeletionOwner(self.db)
        owner.delete_account(SimpleNamespace(login="alice", nodes=[]))
        self.assertEqual(0, self.outbox.stats()["delivery_queue_depth"])


class ReliableWorkerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.db = sqlite3.connect(":memory:")
        self.addCleanup(self.db.close)
        self.broker = FakeRedisBroker()
        self.source = self.worker("source")
        self.target = self.worker("target")
        self.socket = FakeSocket()
        self.target.server.clients["phone"] = self.socket
        self.target.server.client_logins["phone"] = "bob"
        caps = {"reliable_delivery_v1": True}
        self.target.server.client_capabilities["phone"] = caps
        await self.target.register("phone", login="bob", capabilities=caps)

    def worker(self, name):
        server = FakeServer()
        server.client_logins = {}
        server.delivery_outbox = DeliveryOutbox(self.db)
        server.runtime_metrics = RuntimeMetrics()
        worker = RealtimeCoordinator(server, redis_url="redis://test", worker_id=name)
        worker.redis = self.broker.client()
        self.broker.coordinators[worker._worker_channel()] = worker
        return worker

    async def test_lost_pubsub_recovered_from_sql_and_ack_authenticated(self):
        self.broker.coordinators.clear()
        self.assertTrue(await self.source.send_to_node("phone", {
            "type": "chat_message", "message_id": "m1", "text": "test"
        }))
        self.assertEqual([], self.socket.sent)
        await self.target._deliver_pending("phone", self.socket)
        delivery = self.socket.sent[0]["_delivery_id"]
        await self.target._deliver_pending("phone", self.socket)
        self.assertEqual(1, len(self.socket.sent))
        context = SimpleNamespace(node_id="phone")
        await handle_reliable_delivery_ack(self.target.server, {"delivery_id": delivery}, context)
        self.assertEqual(0, self.target.server.delivery_outbox.stats()["delivery_queue_depth"])

    async def test_lost_ack_retried_after_worker_replacement(self):
        await self.source.send_to_node("phone", {"type": "chat_message", "message_id": "m1"})
        replacement = self.worker("replacement")
        socket = FakeSocket()
        replacement.server.clients["phone"] = socket
        replacement.server.client_logins["phone"] = "bob"
        replacement.server.client_capabilities["phone"] = {"reliable_delivery_v1": True}
        await replacement.register("phone", login="bob", capabilities={"reliable_delivery_v1": True})
        self.assertEqual(4002, self.socket.closed[0][0])
        with patch("server.reliable_delivery.time.time", return_value=9999999999):
            await self.target._deliver_pending("phone", self.socket)
            await replacement._deliver_pending("phone", socket)
        self.assertEqual(1, len(self.socket.sent))
        self.assertEqual(self.socket.sent[0]["_delivery_id"], socket.sent[0]["_delivery_id"])

    async def test_failed_socket_keeps_queue(self):
        async def fail(_):
            raise OSError("disconnected")
        self.socket.send = fail
        await self.source.send_to_node("phone", {"type": "chat_message", "message_id": "m1"})
        self.assertEqual(1, self.source.server.delivery_outbox.stats()["delivery_queue_depth"])
        self.assertEqual(1, self.target.server.runtime_metrics.snapshot()["delivery_send_errors_total"])


@unittest.skipUnless(os.environ.get("MESH_TEST_DATABASE_URL"), "isolated PostgreSQL URL required")
class PostgreSQLDeliveryTests(unittest.TestCase):
    def test_two_connections_claim_once_and_ack(self):
        from server.persistence.postgres import connect_postgres, PostgresCompatibilityConnection
        url = os.environ["MESH_TEST_DATABASE_URL"]
        parsed = urlparse(url)
        if parsed.hostname not in {"127.0.0.1", "localhost"} or not parsed.path.startswith("/meshchat_reliability_test"):
            self.fail("Refusing non-local/non-test database")
        a = PostgresCompatibilityConnection(connect_postgres(url))
        b = PostgresCompatibilityConnection(connect_postgres(url))
        try:
            first, second = DeliveryOutbox(a), DeliveryOutbox(b)
            packet = {"type": "chat_message", "message_id": "postgres-test"}
            delivery = first.enqueue("test-phone", "test-user", packet)
            self.assertTrue(first.claim(delivery))
            self.assertFalse(second.claim(delivery))
            self.assertIsNotNone(second.acknowledge("test-phone", "test-user", delivery))
            self.assertEqual([], first.pending("test-phone", "test-user"))
        finally:
            a.close()
            b.close()
