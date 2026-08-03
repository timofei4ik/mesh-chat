from __future__ import annotations

import argparse
import ctypes
import gc
import json
import os
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

if os.name == "nt":
    from ctypes import wintypes


TEST_NAME = (
    "server.tests.test_sync_integration.ServerSyncIntegrationTests."
    "test_two_device_endurance_recovers_from_network_faults"
)
DEFAULT_REPORT = Path("data/sync-endurance.json")
PROJECT_ROOT = Path(__file__).resolve().parents[2]


def _utc_now():
    return datetime.now(timezone.utc).isoformat()


def _write_report(path, report):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def _tail(value, limit=12_000):
    value = str(value or "")
    return value[-limit:]


def _process_resources():
    gc.collect()
    result = {
        "threads": threading.active_count(),
        "gc_objects": len(gc.get_objects()),
    }
    if os.name != "nt":
        try:
            import resource

            usage = resource.getrusage(resource.RUSAGE_SELF)
            multiplier = 1 if sys.platform == "darwin" else 1024
            result["rss_bytes"] = int(usage.ru_maxrss * multiplier)
        except (ImportError, OSError):
            pass
        return result

    try:
        class ProcessMemoryCounters(ctypes.Structure):
            _fields_ = [
                ("cb", wintypes.DWORD),
                ("PageFaultCount", wintypes.DWORD),
                ("PeakWorkingSetSize", ctypes.c_size_t),
                ("WorkingSetSize", ctypes.c_size_t),
                ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                ("PagefileUsage", ctypes.c_size_t),
                ("PeakPagefileUsage", ctypes.c_size_t),
            ]

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        psapi = ctypes.WinDLL("psapi", use_last_error=True)
        kernel32.GetCurrentProcess.restype = wintypes.HANDLE
        process = kernel32.GetCurrentProcess()
        counters = ProcessMemoryCounters()
        counters.cb = ctypes.sizeof(counters)
        psapi.GetProcessMemoryInfo.argtypes = [
            wintypes.HANDLE,
            ctypes.POINTER(ProcessMemoryCounters),
            wintypes.DWORD,
        ]
        psapi.GetProcessMemoryInfo.restype = wintypes.BOOL
        if psapi.GetProcessMemoryInfo(
            process,
            ctypes.byref(counters),
            counters.cb,
        ):
            result["rss_bytes"] = int(counters.WorkingSetSize)
            result["peak_rss_bytes"] = int(counters.PeakWorkingSetSize)
        handle_count = wintypes.DWORD()
        kernel32.GetProcessHandleCount.argtypes = [
            wintypes.HANDLE,
            ctypes.POINTER(wintypes.DWORD),
        ]
        kernel32.GetProcessHandleCount.restype = wintypes.BOOL
        if kernel32.GetProcessHandleCount(
            process,
            ctypes.byref(handle_count),
        ):
            result["handles"] = int(handle_count.value)
    except (AttributeError, OSError, TypeError, ValueError):
        pass
    return result


def _run_round(quiet, timeout_seconds):
    command = [sys.executable, "-m", "unittest"]
    if not quiet:
        command.append("-v")
    command.append(TEST_NAME)
    try:
        completed = subprocess.run(
            command,
            cwd=PROJECT_ROOT,
            env=os.environ.copy(),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout_seconds,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        return {
            "ok": False,
            "return_code": None,
            "timed_out": True,
            "stdout": error.stdout or "",
            "stderr": error.stderr or "",
        }
    if not quiet or completed.returncode:
        if completed.stdout:
            print(completed.stdout, end="", flush=True)
        if completed.stderr:
            print(completed.stderr, end="", file=sys.stderr, flush=True)
    return {
        "ok": completed.returncode == 0,
        "return_code": completed.returncode,
        "timed_out": False,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Run the isolated two-device MeshChat sync endurance test"
    )
    parser.add_argument("--rounds", type=int, default=1)
    parser.add_argument("--iterations", type=int, default=48)
    parser.add_argument("--duration-hours", type=float, default=0.0)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--round-timeout-seconds", type=float, default=600.0)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    rounds = max(1, args.rounds)
    iterations = max(8, min(args.iterations, 2_000))
    duration_seconds = max(0.0, args.duration_hours) * 60 * 60
    round_timeout_seconds = max(30.0, args.round_timeout_seconds)
    started = time.monotonic()
    deadline = started + duration_seconds if duration_seconds else None
    previous_iterations = os.environ.get("MESH_SYNC_ENDURANCE_ITERATIONS")
    os.environ["MESH_SYNC_ENDURANCE_ITERATIONS"] = str(iterations)
    report = {
        "status": "running",
        "started_at": _utc_now(),
        "finished_at": None,
        "iterations_per_round": iterations,
        "requested_rounds": None if deadline else rounds,
        "requested_duration_hours": args.duration_hours if deadline else None,
        "completed_rounds": 0,
        "completed_iterations": 0,
        "elapsed_seconds": 0.0,
        "process_isolation": True,
        "round_timeout_seconds": round_timeout_seconds,
        "failed_round": None,
        "rounds": [],
    }
    _write_report(args.report, report)

    try:
        round_index = 0
        while True:
            if deadline is None and round_index >= rounds:
                break
            if deadline is not None and round_index > 0 and time.monotonic() >= deadline:
                break

            round_started = time.monotonic()
            result = _run_round(args.quiet, round_timeout_seconds)
            round_elapsed = time.monotonic() - round_started
            round_report = {
                "round": round_index + 1,
                "ok": result["ok"],
                "tests_run": 1,
                "return_code": result["return_code"],
                "timed_out": result["timed_out"],
                "elapsed_seconds": round(round_elapsed, 3),
                "stdout_bytes": len(result["stdout"].encode("utf-8")),
                "stderr_bytes": len(result["stderr"].encode("utf-8")),
                "process": _process_resources(),
            }
            if not result["ok"]:
                round_report["stdout_tail"] = _tail(result["stdout"])
                round_report["stderr_tail"] = _tail(result["stderr"])
            report["rounds"].append(round_report)
            report["elapsed_seconds"] = round(time.monotonic() - started, 3)
            if not result["ok"]:
                report["status"] = "failed"
                report["failed_round"] = round_index + 1
                report["finished_at"] = _utc_now()
                _write_report(args.report, report)
                return 1
            report["completed_rounds"] = round_index + 1
            report["completed_iterations"] = (round_index + 1) * iterations
            _write_report(args.report, report)
            round_index += 1

        report["status"] = "passed"
        report["finished_at"] = _utc_now()
        report["elapsed_seconds"] = round(time.monotonic() - started, 3)
        _write_report(args.report, report)
        print(
            "Sync endurance passed: "
            f"{report['completed_rounds']} round(s), "
            f"{report['completed_iterations']} iteration(s).",
            flush=True,
        )
        print(f"Report: {args.report.resolve()}", flush=True)
        return 0
    finally:
        if previous_iterations is None:
            os.environ.pop("MESH_SYNC_ENDURANCE_ITERATIONS", None)
        else:
            os.environ["MESH_SYNC_ENDURANCE_ITERATIONS"] = previous_iterations


if __name__ == "__main__":
    sys.path.insert(0, "")
    raise SystemExit(main())
