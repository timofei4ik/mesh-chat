import json
import time
import unittest

from server.call_signaling import CallSignalingService


class FakeRedis:
    def __init__(self):
        self.hashes = {}
        self.sets = {}
        self.sorted_sets = {}
        self.published = []

    async def hgetall(self, key):
        return dict(self.hashes.get(key, {}))

    async def smembers(self, key):
        return set(self.sets.get(key, set()))

    async def publish(self, channel, value):
        self.published.append((channel, json.loads(value)))
        return 1

    async def zadd(self, key, values):
        self.sorted_sets.setdefault(key, {}).update(values)
        return 1

    async def zrem(self, key, value):
        self.sorted_sets.setdefault(key, {}).pop(value, None)
        return 1


class CallSignalingServiceTests(unittest.IsolatedAsyncioTestCase):
    async def test_routes_to_all_online_devices_of_destination_account(self):
        redis = FakeRedis()
        service = CallSignalingService("redis://test")
        service.redis = redis
        redis.hashes["meshchat:presence:client:bob-phone"] = {
            "login": "bob",
            "worker_id": "worker-a",
            "session_id": "session-a",
        }
        redis.hashes["meshchat:presence:client:bob-desktop"] = {
            "login": "bob",
            "worker_id": "worker-b",
            "session_id": "session-b",
        }
        redis.sets["meshchat:account:client:bob:nodes"] = {
            "bob-phone",
            "bob-desktop",
        }

        delivered = await service.route(
            {
                "type": "call_offer",
                "source_node": "alice-phone",
                "destination_node": "bob-phone",
                "call_id": "call-1",
            }
        )

        self.assertTrue(delivered)
        self.assertEqual(2, len(redis.published))
        routed = [
            envelope["packet"]
            for _, envelope in redis.published
        ]
        desktop = next(
            packet
            for packet in routed
            if packet["destination_node"] == "bob-desktop"
        )
        self.assertEqual(
            "bob-phone",
            desktop["original_destination_node"],
        )
        self.assertGreater(
            redis.sorted_sets[service.active_calls_key]["call-1"],
            time.time(),
        )

    async def test_call_end_removes_active_call(self):
        redis = FakeRedis()
        service = CallSignalingService("redis://test")
        service.redis = redis
        redis.sorted_sets[service.active_calls_key] = {
            "call-1": time.time() + 100,
        }
        redis.hashes["meshchat:presence:client:bob"] = {
            "worker_id": "worker-a",
            "session_id": "session-a",
        }

        await service.route(
            {
                "type": "call_end",
                "source_node": "alice",
                "destination_node": "bob",
                "call_id": "call-1",
            }
        )

        self.assertNotIn(
            "call-1",
            redis.sorted_sets[service.active_calls_key],
        )

    async def test_handoff_routes_only_to_the_selected_device(self):
        redis = FakeRedis()
        service = CallSignalingService("redis://test")
        service.redis = redis
        for node, worker, session in (
            ("alice-phone", "worker-a", "session-a"),
            ("alice-desktop", "worker-b", "session-b"),
        ):
            redis.hashes[f"meshchat:presence:client:{node}"] = {
                "login": "alice",
                "worker_id": worker,
                "session_id": session,
            }
        redis.sets["meshchat:account:client:alice:nodes"] = {
            "alice-phone",
            "alice-desktop",
        }

        delivered = await service.route(
            {
                "type": "call_handoff_request",
                "source_node": "alice-phone",
                "destination_node": "alice-desktop",
                "call_id": "call-handoff",
            }
        )

        self.assertTrue(delivered)
        self.assertEqual(1, len(redis.published))
        self.assertEqual(
            "alice-desktop",
            redis.published[0][1]["packet"]["destination_node"],
        )

    async def test_handoff_offer_routes_only_to_active_peer_device(self):
        redis = FakeRedis()
        service = CallSignalingService("redis://test")
        service.redis = redis
        for node, worker, session in (
            ("bob-phone", "worker-a", "session-a"),
            ("bob-desktop", "worker-b", "session-b"),
        ):
            redis.hashes[f"meshchat:presence:client:{node}"] = {
                "login": "bob",
                "worker_id": worker,
                "session_id": session,
            }
        redis.sets["meshchat:account:client:bob:nodes"] = {
            "bob-phone",
            "bob-desktop",
        }

        delivered = await service.route(
            {
                "type": "call_offer",
                "source_node": "alice-desktop",
                "destination_node": "bob-phone",
                "call_id": "call-handoff-new",
                "handoff_from_call_id": "call-handoff-old",
            }
        )

        self.assertTrue(delivered)
        self.assertEqual(1, len(redis.published))
        self.assertEqual(
            "bob-phone",
            redis.published[0][1]["packet"]["destination_node"],
        )
