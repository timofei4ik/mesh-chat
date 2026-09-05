import asyncio
import json
import unittest
from unittest.mock import patch
from types import SimpleNamespace

from server.server_realtime import RealtimeCoordinator


class FakeSocket:
    def __init__(self):
        self.sent = []
        self.closed = []

    async def send(self, value):
        self.sent.append(json.loads(value))

    async def close(self, code=1000, reason=""):
        self.closed.append((code, reason))


class FakeServer:
    def __init__(self):
        self.clients = {}
        self.service_clients = {}
        self.client_capabilities = {}


class FakeRedisBroker:
    def __init__(self):
        self.hashes = {}
        self.sets = {}
        self.values = {}
        self.expirations = {}
        self.coordinators = {}

    def client(self):
        return FakeRedisClient(self)

    async def publish(self, channel, value):
        coordinator = self.coordinators.get(channel)
        if coordinator is None:
            return 0
        await coordinator._handle_envelope(json.loads(value))
        return 1


class FakePipeline:
    def __init__(self, client):
        self.client = client
        self.operations = []

    def hset(self, *args, **kwargs):
        self.operations.append(("hset", args, kwargs))
        return self

    def hgetall(self, *args, **kwargs):
        self.operations.append(("hgetall", args, kwargs))
        return self

    def expire(self, *args, **kwargs):
        self.operations.append(("expire", args, kwargs))
        return self

    def sadd(self, *args, **kwargs):
        self.operations.append(("sadd", args, kwargs))
        return self

    def eval(self, *args, **kwargs):
        self.operations.append(("eval", args, kwargs))
        return self

    def set(self, *args, **kwargs):
        self.operations.append(("set", args, kwargs))
        return self

    async def execute(self):
        results = []
        for name, args, kwargs in self.operations:
            results.append(await getattr(self.client, name)(*args, **kwargs))
        return results


class FakeRedisClient:
    def __init__(self, broker):
        self.broker = broker

    async def hset(self, key, mapping):
        self.broker.hashes[key] = {
            str(name): str(value)
            for name, value in mapping.items()
        }
        return len(mapping)

    async def hgetall(self, key):
        return dict(self.broker.hashes.get(key, {}))

    async def hget(self, key, field):
        return self.broker.hashes.get(key, {}).get(field)

    async def expire(self, key, seconds):
        self.broker.expirations[key] = seconds
        return key in self.broker.hashes or key in self.broker.sets

    async def sadd(self, key, *members):
        values = self.broker.sets.setdefault(key, set())
        before = len(values)
        values.update(str(member) for member in members)
        return len(values) - before

    async def smembers(self, key):
        return set(self.broker.sets.get(key, set()))

    async def srem(self, key, *members):
        values = self.broker.sets.setdefault(key, set())
        before = len(values)
        values.difference_update(str(member) for member in members)
        return before - len(values)

    async def publish(self, channel, value):
        return await self.broker.publish(channel, value)

    async def set(self, key, value, nx=False, ex=None):
        if nx and key in self.broker.values:
            return None
        self.broker.values[key] = value
        return True

    def pipeline(self, transaction=True):
        return FakePipeline(self)

    async def eval(self, script, key_count, *args):
        key = args[0]
        session_id = args[key_count]
        record = self.broker.hashes.get(key, {})
        if "cjson.decode" in script:
            if record and record.get("session_id") != str(session_id):
                return 0
            if not record:
                await self.hset(key, json.loads(args[key_count + 2]))
            await self.expire(key, args[key_count + 1])
            if args[key_count + 3]:
                await self.sadd(args[1], args[key_count + 4])
                await self.expire(args[1], args[key_count + 1] * 4)
            return 1
        if record.get("session_id") != str(session_id):
            return 0
        if "DEL" in script:
            account_key = args[1]
            node_id = str(args[key_count + 2])
            self.broker.hashes.pop(key, None)
            self.broker.sets.setdefault(account_key, set()).discard(node_id)
        return 1


class RealtimeCoordinatorTests(unittest.IsolatedAsyncioTestCase):
    async def test_slow_sync_hint_does_not_block_fast_receiver_and_coalesces(self):
        broker = FakeRedisBroker()
        server, coordinator = self.make_coordinator(broker, "worker-a")
        server.client_logins = {"slow": "alice", "fast": "bob"}
        server.sync_delivery_queue = SimpleNamespace(pending_cursor=lambda *_: 42)
        server.runtime_metrics = SimpleNamespace(increment=lambda *_: None)
        release = asyncio.Event()
        slow, fast = FakeSocket(), FakeSocket()
        async def blocked_send(_):
            await release.wait()
        slow.send = blocked_send
        for node, socket in (("slow", slow), ("fast", fast)):
            server.clients[node] = socket
            server.client_capabilities[node] = {"reliable_sync_v2": True}
            await coordinator.register(node, login=server.client_logins[node])
        coordinator._schedule_sync_hint("slow", slow, force=True)
        for _ in range(100):
            coordinator._schedule_sync_hint("slow", slow, force=True)
        self.assertEqual(1, len(coordinator._hint_tasks))
        coordinator._sync_retries["fast"] = (
            coordinator._local_sessions[("client", "fast")],
            asyncio.get_running_loop().time() + 30, 1)
        coordinator._schedule_sync_hint("fast", fast)
        await coordinator._handle_envelope({"action": "sync_ready", "node_id": "fast",
            "session_id": coordinator._local_sessions[("client", "fast")]})
        try:
            await asyncio.wait_for(coordinator._hint_tasks["fast"][2], .5)
            self.assertEqual(42, fast.sent[0]["cursor"])
            self.assertFalse(coordinator._hint_tasks["slow"][2].done())
        finally:
            tasks = [entry[2] for entry in coordinator._hint_tasks.values()]
            release.set()
            await asyncio.gather(*tasks)

    async def test_disconnect_clears_hint_cancelled_before_first_execution(self):
        coordinator = RealtimeCoordinator(FakeServer())
        session = await coordinator.register("node", login="alice")
        coordinator._schedule_sync_hint("node", FakeSocket())
        task = coordinator._hint_tasks["node"][2]
        await coordinator.unregister("node", session)
        await asyncio.gather(task, return_exceptions=True)
        self.assertEqual({}, coordinator._hint_tasks)

    def make_coordinator(self, broker, worker_id):
        server = FakeServer()
        coordinator = RealtimeCoordinator(
            server,
            redis_url="redis://test",
            worker_id=worker_id,
        )
        coordinator.redis = broker.client()
        broker.coordinators[coordinator._worker_channel()] = coordinator
        return server, coordinator

    async def test_packet_crosses_worker_boundary_once(self):
        broker = FakeRedisBroker()
        _, source = self.make_coordinator(broker, "worker-a")
        target_server, target = self.make_coordinator(broker, "worker-b")
        socket = FakeSocket()
        target_server.clients["bob-phone"] = socket
        target_server.client_capabilities["bob-phone"] = {
            "account_live_fanout": True,
        }
        session_id = await target.register(
            "bob-phone",
            login="bob",
            username="Bob",
            capabilities={"account_live_fanout": True},
        )

        delivered = await source.send_to_node(
            "bob-phone",
            {"type": "chat_message", "text": "hello"},
        )

        self.assertTrue(delivered)
        self.assertEqual("hello", socket.sent[0]["text"])
        self.assertEqual(
            ["bob-phone"],
            await source.account_nodes("bob"),
        )
        self.assertEqual(
            session_id,
            target._local_sessions[("client", "bob-phone")],
        )

    async def test_stale_disconnect_cannot_remove_new_session(self):
        broker = FakeRedisBroker()
        _, first = self.make_coordinator(broker, "worker-a")
        second_server, second = self.make_coordinator(broker, "worker-b")
        second_server.clients["same-node"] = FakeSocket()

        old_session = await first.register("same-node", login="alice")
        new_session = await second.register("same-node", login="alice")
        removed = await first.unregister("same-node", old_session)

        self.assertFalse(removed)
        presence = await second.redis.hgetall(
            second._presence_key("same-node")
        )
        self.assertEqual(new_session, presence["session_id"])
        self.assertEqual(["same-node"], await first.account_nodes("alice"))

    async def test_operation_claim_is_shared_between_workers(self):
        broker = FakeRedisBroker()
        _, first = self.make_coordinator(broker, "worker-a")
        _, second = self.make_coordinator(broker, "worker-b")

        self.assertTrue(
            await first.claim_operation("call-end", "operation-1")
        )
        self.assertFalse(
            await second.claim_operation("call-end", "operation-1")
        )

    async def test_worker_heartbeat_is_refreshed_without_sessions(self):
        broker = FakeRedisBroker()
        _, coordinator = self.make_coordinator(broker, "worker-empty")

        await coordinator._refresh_heartbeat()

        self.assertIn(coordinator._worker_key(), broker.values)

    async def test_heartbeat_restores_presence_after_broker_data_loss(self):
        broker = FakeRedisBroker()
        server, coordinator = self.make_coordinator(broker, "worker-a")
        server.clients["alice-phone"] = FakeSocket()
        session = await coordinator.register("alice-phone", login="Alice",
            capabilities={"reliable_sync_v2": True})
        broker.hashes.clear()
        broker.sets.clear()
        await coordinator._refresh_heartbeat()
        restored = await coordinator.redis.hgetall(coordinator._presence_key("alice-phone"))
        self.assertEqual(session, restored["session_id"])
        self.assertTrue(json.loads(restored["capabilities"])["reliable_sync_v2"])
        self.assertEqual(["alice-phone"], await coordinator.account_nodes("alice"))

    async def test_heartbeat_renews_account_membership_too(self):
        broker = FakeRedisBroker()
        server, coordinator = self.make_coordinator(broker, "worker-a")
        server.clients["alice-phone"] = FakeSocket()
        await coordinator.register("alice-phone", login="alice")
        broker.sets.clear()
        broker.expirations.clear()
        await coordinator._refresh_heartbeat()
        self.assertEqual(["alice-phone"], await coordinator.account_nodes("alice"))
        self.assertEqual(coordinator.presence_ttl * 4,
                         broker.expirations[coordinator._account_key("alice")])

    async def test_stale_heartbeat_never_overwrites_replacement(self):
        broker = FakeRedisBroker()
        first_server, first = self.make_coordinator(broker, "worker-a")
        second_server, second = self.make_coordinator(broker, "worker-b")
        old_socket = FakeSocket()
        first_server.clients["same-node"] = old_socket
        second_server.clients["same-node"] = FakeSocket()
        await first.register("same-node", login="alice")
        # Drop the close notification, as can happen during broker disconnect.
        broker.coordinators.clear()
        new_session = await second.register("same-node", login="alice")
        await first._refresh_heartbeat()
        record = await second.redis.hgetall(second._presence_key("same-node"))
        self.assertEqual(new_session, record["session_id"])
        self.assertEqual(4002, old_socket.closed[-1][0])
        broker.hashes.clear()
        await first._refresh_heartbeat()
        self.assertFalse(await first.redis.hgetall(first._presence_key("same-node")))

    async def test_disconnected_session_is_not_restored(self):
        broker = FakeRedisBroker()
        server, coordinator = self.make_coordinator(broker, "worker-a")
        server.clients["alice-phone"] = FakeSocket()
        session = await coordinator.register("alice-phone", login="alice")
        await coordinator.unregister("alice-phone", session)
        await coordinator._refresh_heartbeat()
        self.assertFalse(await coordinator.redis.hgetall(coordinator._presence_key("alice-phone")))

    async def test_disconnect_waits_for_inflight_presence_restore(self):
        broker = FakeRedisBroker()
        server, coordinator = self.make_coordinator(broker, "worker-a")
        server.clients["alice-phone"] = FakeSocket()
        session = await coordinator.register("alice-phone", login="alice")
        broker.hashes.clear()
        started, release = asyncio.Event(), asyncio.Event()
        original = coordinator.redis.eval

        async def delayed_eval(script, *args):
            if "cjson.decode" in script:
                started.set()
                await asyncio.wait_for(release.wait(), 2)
            return await original(script, *args)

        with patch.object(coordinator.redis, "eval", side_effect=delayed_eval):
            heartbeat = asyncio.create_task(coordinator._refresh_heartbeat())
            await asyncio.wait_for(started.wait(), 2)
            disconnect = asyncio.create_task(coordinator.unregister("alice-phone", session))
            await asyncio.sleep(0)
            self.assertFalse(disconnect.done())
            release.set()
            await asyncio.gather(heartbeat, disconnect)
        self.assertFalse(await coordinator.redis.hgetall(coordinator._presence_key("alice-phone")))
