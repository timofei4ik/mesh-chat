import unittest
from unittest.mock import AsyncMock
from redis.exceptions import ResponseError, ConnectionError
from server.observability_service import MeshMetrics
from server.runtime_metrics import RuntimeMetrics


class RuntimeMetricsTests(unittest.TestCase):
    def test_bounded_names_and_cumulative_buckets(self):
        metrics = RuntimeMetrics()
        metrics.observe("delivery_ack", .2)
        values = metrics.snapshot()
        self.assertEqual(0, values["delivery_ack_seconds_bucket_0.1"])
        self.assertEqual(1, values["delivery_ack_seconds_bucket_0.25"])
        self.assertEqual(1, values["delivery_ack_seconds_count"])
        with self.assertRaises(ValueError):
            metrics.increment("user-secret-text")
        with self.assertRaises(ValueError):
            metrics.observe("sync", float("inf"))


class MetricsTests(unittest.IsolatedAsyncioTestCase):
    def make_metrics(self):
        metrics = MeshMetrics("redis://test")
        metrics.redis = AsyncMock()
        metrics.redis.zcard.return_value = 0
        metrics.redis.xlen.return_value = 0
        async def scan_iter(match, count):
            if "worker:heartbeat" in match:
                yield "worker-a"
            if "worker:metrics" in match:
                yield "metrics-a"
                yield "metrics-b"
        metrics.redis.scan_iter = scan_iter
        metrics.redis.hgetall.return_value = {
            "delivery_queue_depth": "3", "delivery_acked_total": "5",
            "event_loop_lag_seconds": ".01", "private_message": "secret",
        }
        return metrics

    async def test_missing_call_stream_does_not_mark_redis_down(self):
        metrics = self.make_metrics()
        metrics.redis.xinfo_groups.side_effect = ResponseError("no such key")
        values = await metrics.collect()
        self.assertEqual(1, values["redis_up"])
        self.assertEqual(1, values["chat_workers"])
        self.assertEqual(0, values["call_signal_pending"])
        self.assertEqual(3, values["delivery_queue_depth"])
        self.assertEqual(10, values["delivery_acked_total"])
        output = await metrics.prometheus()
        self.assertNotIn("secret", output)
        self.assertIn('meshchat_delivery_ack_seconds_bucket{worker="metrics-a",le="+Inf"}', output)

    async def test_connection_failure_is_reported(self):
        metrics = self.make_metrics()
        metrics.redis.ping.side_effect = ConnectionError("offline")
        self.assertEqual(0, (await metrics.collect())["redis_up"])
