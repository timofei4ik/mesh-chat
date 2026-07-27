"""Local failover guard for a single-host MeshChat deployment."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request

STATE_PATH = Path(
    os.environ.get(
        "MESH_FAILOVER_STATE_PATH",
        "/run/meshchat-failover-state.json",
    )
)


def http_ok(url, timeout=3):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            return response.status == 200
    except Exception:
        return False


def restart(unit):
    return subprocess.run(
        ["systemctl", "restart", unit],
        check=False,
        capture_output=True,
        text=True,
    ).returncode == 0


def unit_active(unit):
    return (
        subprocess.run(
            ["systemctl", "is-active", "--quiet", unit],
            check=False,
        ).returncode
        == 0
    )


def collect_checks():
    return {
        # systemd already restarts crashed workers. Avoid probing their busy
        # WebSocket event loops, which can turn a load spike into a restart.
        "chat_worker_0": unit_active("mesh-chat-worker@0.service"),
        "chat_worker_1": unit_active("mesh-chat-worker@1.service"),
        "call_signaling_0": (
            unit_active("mesh-call-signaling@0.service")
            and http_ok("http://127.0.0.1:8781/health")
        ),
        "call_signaling_1": (
            unit_active("mesh-call-signaling@1.service")
            and http_ok("http://127.0.0.1:8782/health")
        ),
        "media": (
            unit_active("mesh-media.service")
            and http_ok("http://127.0.0.1:8777/media/health")
        ),
        "metrics": (
            unit_active("mesh-metrics.service")
            and http_ok("http://127.0.0.1:8780/health")
        ),
    }


def load_failure_counts():
    try:
        payload = json.loads(STATE_PATH.read_text(encoding="utf-8"))
        return {
            str(name): max(0, int(value))
            for name, value in payload.get("failure_counts", {}).items()
        }
    except (OSError, ValueError, TypeError):
        return {}


def save_failure_counts(counts):
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    temporary = STATE_PATH.with_suffix(".tmp")
    temporary.write_text(
        json.dumps({"failure_counts": counts}, sort_keys=True),
        encoding="utf-8",
    )
    temporary.replace(STATE_PATH)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--failure-threshold", type=int, default=3)
    args = parser.parse_args()
    checks = collect_checks()
    recovery = {}
    unit_map = {
        "chat_worker_0": "mesh-chat-worker@0.service",
        "chat_worker_1": "mesh-chat-worker@1.service",
        "call_signaling_0": "mesh-call-signaling@0.service",
        "call_signaling_1": "mesh-call-signaling@1.service",
        "media": "mesh-media.service",
        "metrics": "mesh-metrics.service",
    }
    previous_failures = load_failure_counts()
    failure_counts = {
        name: 0 if healthy else previous_failures.get(name, 0) + 1
        for name, healthy in checks.items()
    }
    if args.apply:
        for name, healthy in checks.items():
            if (
                not healthy
                and failure_counts[name] >= max(1, args.failure_threshold)
            ):
                recovery[name] = restart(unit_map[name])
        if recovery:
            time.sleep(3)
            checks = collect_checks()
            for name, healthy in checks.items():
                if healthy:
                    failure_counts[name] = 0
    save_failure_counts(failure_counts)
    unrecovered = [
        name
        for name in recovery
        if not checks.get(name, False)
    ]
    state = {
        "status": "ok" if all(checks.values()) else "degraded",
        "checks": checks,
        "failure_counts": failure_counts,
        "failure_threshold": max(1, args.failure_threshold),
        "recovery": recovery,
        "call_fallback_active": not (
            checks["call_signaling_0"]
            or checks["call_signaling_1"]
        ),
    }
    print(json.dumps(state, sort_keys=True))
    raise SystemExit(1 if unrecovered else 0)


if __name__ == "__main__":
    main()
