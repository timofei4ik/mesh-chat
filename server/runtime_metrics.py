"""Bounded aggregate transport metrics. Never store packet text or identities."""

import time
import math
from collections import Counter


class RuntimeMetrics:
    COUNTERS = frozenset({
        "delivery_enqueued_total", "delivery_attempts_total", "delivery_acked_total",
        "delivery_send_errors_total", "sync_completed_total", "sync_failed_total",
        "mutations_committed_total", "mutations_rejected_total", "file_errors_total",
        "delivery_capacity_rejections_total",
    })
    TIMINGS = frozenset({"delivery_ack", "mutation_commit", "sync"})
    BUCKETS = (0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 120)

    def __init__(self):
        self.values = Counter()
        self.started_at = time.monotonic()
        self.event_loop_lag = 0.0

    def increment(self, name):
        if name not in self.COUNTERS:
            raise ValueError("Unknown metric")
        self.values[name] += 1

    def observe(self, name, seconds):
        if name not in self.TIMINGS:
            raise ValueError("Unknown timing")
        value = max(0.0, float(seconds))
        if not math.isfinite(value):
            raise ValueError("Timing must be finite")
        self.values[f"{name}_seconds_count"] += 1
        self.values[f"{name}_seconds_sum"] += value
        for upper in self.BUCKETS:
            if value <= upper:
                self.values[f"{name}_seconds_bucket_{upper}"] += 1

    def snapshot(self):
        values = {name: self.values[name] for name in self.COUNTERS}
        for name in self.TIMINGS:
            for suffix in ("count", "sum", *(f"bucket_{b}" for b in self.BUCKETS)):
                key = f"{name}_seconds_{suffix}"
                values[key] = self.values[key]
        return {**values, "event_loop_lag_seconds": self.event_loop_lag}
