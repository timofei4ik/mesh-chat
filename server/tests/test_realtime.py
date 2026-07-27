import json
import unittest

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
        if record.get("session_id") != str(session_id):
            return 0
        if "DEL" in script:
            account_key = args[1]
            node_id = str(args[key_count + 2])
            self.broker.hashes.pop(key, None)
            self.broker.sets.setdefault(account_key, set()).discard(node_id)
        return 1


class RealtimeCoordinatorTests(unittest.IsolatedAsyncioTestCase):
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
