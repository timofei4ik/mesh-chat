from __future__ import annotations

import argparse
import asyncio
import json
import os
import shutil
import sqlite3
import subprocess
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

import websockets


ROOT_DIR = Path(__file__).resolve().parents[2]

if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))

from server.config import DB_PATH, PORT
from server.server_storage import (
    OFFLINE_PACKET_MAX_AGE_DAYS,
    OFFLINE_QUEUE_PACKET_TYPES,
)


DEFAULT_BACKUP_DIR = ROOT_DIR / "backups" / "automatic"
DEFAULT_STATUS_PATH = ROOT_DIR / "data" / "health.json"


def resolve_path(path):
    resolved = Path(path)
    if not resolved.is_absolute():
        resolved = ROOT_DIR / resolved
    return resolved.resolve()


def _run_systemctl(*args):
    result = subprocess.run(
        ["systemctl", *args],
        capture_output=True,
        check=False,
        text=True,
        timeout=5,
    )
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def _latest_backup(backup_dir, now):
    backup_dir = Path(backup_dir)
    backups = sorted(
        backup_dir.glob("server-*.db.gz"),
        key=lambda item: item.stat().st_mtime,
        reverse=True,
    )
    if not backups:
        return None
    latest = backups[0]
    modified = datetime.fromtimestamp(latest.stat().st_mtime, timezone.utc)
    return {
        "path": str(latest),
        "bytes": latest.stat().st_size,
        "age_hours": round((now - modified).total_seconds() / 3600, 2),
    }


async def _check_websocket(host, port):
    async with websockets.connect(
        f"ws://{host}:{int(port)}",
        open_timeout=2,
        close_timeout=2,
    ):
        return True


def _database_health(database_path):
    uri = f"{database_path.as_uri()}?mode=ro"
    conn = sqlite3.connect(uri, uri=True, timeout=10)
    try:
        quick_check = [row[0] for row in conn.execute("PRAGMA quick_check").fetchall()]
        queue_rows = conn.execute(
            """
            SELECT destination_node,
                   packet_json,
                   created_at < DATETIME('now', ?) AS expired
            FROM offline_packets
            """,
            (f"-{OFFLINE_PACKET_MAX_AGE_DAYS} days",),
        ).fetchall()
        packet_types = Counter()
        server_packets = 0
        unsupported_packets = 0
        expired_packets = 0
        for destination_node, packet_json, expired in queue_rows:
            server_packets += int(
                str(destination_node or "").strip().upper() == "SERVER"
            )
            try:
                packet = json.loads(packet_json)
                packet_type = (
                    str(packet.get("type") or "")
                    if isinstance(packet, dict)
                    else ""
                )
            except (TypeError, ValueError):
                packet_type = "<invalid>"
            packet_types[packet_type] += 1
            unsupported_packets += int(
                packet_type not in OFFLINE_QUEUE_PACKET_TYPES
            )
            expired_packets += int(bool(expired))

        orphan_reactions = conn.execute(
            """
            SELECT COUNT(*)
            FROM server_reactions
            WHERE NOT EXISTS(
                SELECT 1 FROM direct_messages
                WHERE direct_messages.message_id=server_reactions.message_id
            )
            AND NOT EXISTS(
                SELECT 1 FROM server_group_messages
                WHERE server_group_messages.message_id=server_reactions.message_id
            )
            AND NOT EXISTS(
                SELECT 1 FROM server_files
                WHERE server_files.file_id=server_reactions.message_id
            )
            """
        ).fetchone()[0]

        counts = {}
        for table in (
            "accounts",
            "account_devices",
            "direct_messages",
            "server_groups",
            "server_group_messages",
            "server_files",
            "server_stories",
            "server_sticker_libraries",
        ):
            counts[table] = conn.execute(
                f'SELECT COUNT(*) FROM "{table}"'
            ).fetchone()[0]

        return {
            "quick_check": quick_check,
            "counts": counts,
            "offline_queue": {
                "total": len(queue_rows),
                "server": server_packets,
                "unsupported": unsupported_packets,
                "expired": expired_packets,
                "types": dict(sorted(packet_types.items())),
            },
            "orphan_reactions": orphan_reactions,
        }
    finally:
        conn.close()


def collect_health(
    database_path,
    backup_dir,
    service_name="mesh-server",
    host="127.0.0.1",
    port=PORT,
    check_service=True,
    check_port=True,
):
    now = datetime.now(timezone.utc)
    database_path = resolve_path(database_path)
    backup_dir = resolve_path(backup_dir)
    critical = []
    warnings = []

    service = {"checked": check_service}
    if check_service:
        code, state, error = _run_systemctl("is-active", service_name)
        service["active"] = code == 0 and state == "active"
        service["state"] = state or error or "unknown"
        restarts_code, restarts, _ = _run_systemctl(
            "show",
            service_name,
            "-p",
            "NRestarts",
            "--value",
        )
        service["restarts"] = (
            int(restarts) if restarts_code == 0 and restarts.isdigit() else None
        )
        if not service["active"]:
            critical.append(f"service {service_name} is not active")
        if service["restarts"]:
            warnings.append(f"service restarted {service['restarts']} time(s)")

    port_status = {"checked": check_port, "host": host, "port": int(port)}
    if check_port:
        try:
            port_status["open"] = asyncio.run(_check_websocket(host, port))
        except Exception as error:
            port_status["open"] = False
            port_status["error"] = str(error)
            critical.append(f"WebSocket {host}:{port} is not reachable")

    database = {"path": str(database_path), "exists": database_path.is_file()}
    if database["exists"]:
        database["bytes"] = database_path.stat().st_size
        try:
            database.update(_database_health(database_path))
            if database["quick_check"] != ["ok"]:
                critical.append("database quick_check failed")
            queue = database["offline_queue"]
            if queue["server"]:
                warnings.append(f"offline queue contains {queue['server']} SERVER packet(s)")
            if queue["unsupported"]:
                warnings.append(
                    f"offline queue contains {queue['unsupported']} unsupported packet(s)"
                )
            if queue["expired"]:
                warnings.append(f"offline queue contains {queue['expired']} expired packet(s)")
            if queue["total"] > 500:
                warnings.append(f"offline queue is large: {queue['total']} packet(s)")
            if database["orphan_reactions"]:
                warnings.append(
                    f"database contains {database['orphan_reactions']} orphan reaction(s)"
                )
        except (OSError, sqlite3.Error) as error:
            database["error"] = str(error)
            critical.append(f"database check failed: {error}")
    else:
        critical.append(f"database is missing: {database_path}")

    disk = shutil.disk_usage(database_path.parent if database_path.parent.exists() else ROOT_DIR)
    disk_status = {
        "total": disk.total,
        "used": disk.used,
        "free": disk.free,
        "free_percent": round(disk.free * 100 / disk.total, 2),
    }
    if disk.free < 512 * 1024 * 1024:
        critical.append("less than 512 MB of disk space remains")
    elif disk.free < 2 * 1024 * 1024 * 1024 or disk_status["free_percent"] < 10:
        warnings.append("server disk space is running low")

    latest_backup = _latest_backup(backup_dir, now)
    if latest_backup is None:
        warnings.append("no automatic backup found")
    elif latest_backup["age_hours"] > 36:
        warnings.append(
            f"latest automatic backup is {latest_backup['age_hours']} hours old"
        )

    state = "critical" if critical else "warning" if warnings else "ok"
    return {
        "checked_at": now.isoformat(),
        "status": state,
        "critical": critical,
        "warnings": warnings,
        "service": service,
        "port": port_status,
        "database": database,
        "disk": disk_status,
        "latest_backup": latest_backup,
    }


def write_status(status, path):
    path = resolve_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(status, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)
    try:
        path.chmod(0o600)
    except OSError:
        pass


def main():
    parser = argparse.ArgumentParser(description="Check MeshChat relay health")
    parser.add_argument(
        "--database",
        default=os.environ.get("MESH_SERVER_DB", str(DB_PATH)),
    )
    parser.add_argument(
        "--backup-dir",
        default=os.environ.get("MESH_BACKUP_DIR", str(DEFAULT_BACKUP_DIR)),
    )
    parser.add_argument(
        "--status-file",
        default=os.environ.get("MESH_HEALTH_STATUS", str(DEFAULT_STATUS_PATH)),
    )
    parser.add_argument("--service", default="mesh-server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=PORT)
    parser.add_argument("--no-service-check", action="store_true")
    parser.add_argument("--no-port-check", action="store_true")
    args = parser.parse_args()

    status = collect_health(
        args.database,
        args.backup_dir,
        service_name=args.service,
        host=args.host,
        port=args.port,
        check_service=not args.no_service_check,
        check_port=not args.no_port_check,
    )
    write_status(status, args.status_file)
    print(json.dumps(status, ensure_ascii=True, sort_keys=True))
    raise SystemExit(2 if status["status"] == "critical" else 0)


if __name__ == "__main__":
    main()
