from __future__ import annotations

import argparse
import asyncio
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import urllib.request
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

import websockets


ROOT_DIR = Path(__file__).resolve().parents[2]

if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))

from server.config import DATABASE_BACKEND, DATABASE_URL, DB_PATH, PORT
from server.persistence import connect_postgres
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
        [
            *backup_dir.glob("server-*.db.gz"),
            *backup_dir.glob("server-*.pgdump"),
        ],
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


def _check_http_health_details(url):
    request = urllib.request.Request(
        str(url),
        headers={"User-Agent": "mesh-health/1"},
    )
    with urllib.request.urlopen(request, timeout=3) as response:
        if int(response.status) != 200:
            return False, f"HTTP {response.status}"
        payload = json.loads(response.read().decode("utf-8"))
    if payload.get("ok") is not True:
        return False, "health payload is not ok", payload
    return True, "", payload


def _check_http_health(url):
    healthy, error, _payload = _check_http_health_details(url)
    return healthy, error


def _media_metric_warnings(metrics):
    metrics = metrics if isinstance(metrics, dict) else {}
    warnings = []
    invalid_media = int(metrics.get("invalid_media_total") or 0)
    server_errors = int(metrics.get("server_errors_total") or 0)
    if invalid_media:
        warnings.append(
            f"media delivery reported {invalid_media} invalid object(s)"
        )
    if server_errors:
        warnings.append(
            f"media delivery reported {server_errors} server error(s)"
        )
    return warnings


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


def _postgres_database_health(database_url):
    conn = connect_postgres(database_url)
    try:
        queue_rows = conn.execute(
            f"""
            SELECT destination_node,
                   packet_json,
                   created_at < (
                       CURRENT_TIMESTAMP
                       - INTERVAL '{int(OFFLINE_PACKET_MAX_AGE_DAYS)} days'
                   ) AS expired
            FROM offline_packets
            """
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
                packet = (
                    packet_json
                    if isinstance(packet_json, dict)
                    else json.loads(packet_json)
                )
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
            "backend": "postgres",
            "quick_check": ["ok"],
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
    http_health_url="",
    media_health_url="",
    database_backend=DATABASE_BACKEND,
    database_url=DATABASE_URL,
):
    now = datetime.now(timezone.utc)
    database_path = resolve_path(database_path)
    backup_dir = resolve_path(backup_dir)
    critical = []
    warnings = []

    service_names = (
        [
            value.strip()
            for value in str(service_name or "").split(",")
            if value.strip()
        ]
        or ["mesh-server"]
    )
    service = {
        "checked": check_service,
        "name": ",".join(service_names),
        "instances": [],
    }
    if check_service:
        restart_total = 0
        for current_name in service_names:
            code, state, error = _run_systemctl(
                "is-active",
                current_name,
            )
            active = code == 0 and state == "active"
            restarts_code, restarts, _ = _run_systemctl(
                "show",
                current_name,
                "-p",
                "NRestarts",
                "--value",
            )
            restart_count = (
                int(restarts)
                if restarts_code == 0 and restarts.isdigit()
                else None
            )
            service["instances"].append(
                {
                    "name": current_name,
                    "active": active,
                    "state": state or error or "unknown",
                    "restarts": restart_count,
                }
            )
            if not active:
                critical.append(f"service {current_name} is not active")
            if restart_count:
                restart_total += restart_count
                warnings.append(
                    f"service {current_name} restarted "
                    f"{restart_count} time(s)"
                )
        service["active"] = all(
            item["active"]
            for item in service["instances"]
        )
        service["state"] = (
            "active" if service["active"] else "degraded"
        )
        service["restarts"] = restart_total

    ports = [
        int(value)
        for value in (
            port
            if isinstance(port, (list, tuple, set))
            else str(port).split(",")
        )
        if str(value).strip()
    ]
    port_status = {
        "checked": check_port,
        "host": host,
        "port": ports[0] if len(ports) == 1 else None,
        "ports": [],
    }
    if check_port:
        for current_port in ports:
            current_status = {"port": current_port}
            try:
                current_status["open"] = asyncio.run(
                    _check_websocket(host, current_port)
                )
            except Exception as error:
                current_status["open"] = False
                current_status["error"] = str(error)
                critical.append(
                    f"WebSocket {host}:{current_port} is not reachable"
                )
            port_status["ports"].append(current_status)
        port_status["open"] = bool(ports) and all(
            item["open"]
            for item in port_status["ports"]
        )

    http_health = {
        "checked": bool(http_health_url),
        "url": str(http_health_url or ""),
    }
    if http_health_url:
        try:
            healthy, error = _check_http_health(http_health_url)
        except Exception as error:
            healthy = False
            error = str(error)
        http_health["ok"] = bool(healthy)
        if error:
            http_health["error"] = str(error)
        if not healthy:
            critical.append(
                f"HTTP health endpoint {http_health_url} is not healthy"
            )

    media_health = {
        "checked": bool(media_health_url),
        "url": str(media_health_url or ""),
    }
    if media_health_url:
        try:
            healthy, error, payload = _check_http_health_details(
                media_health_url
            )
        except Exception as error:
            healthy = False
            payload = {}
            error = str(error)
        media_health["ok"] = bool(healthy)
        media_health["metrics"] = (
            payload.get("metrics", {})
            if isinstance(payload, dict)
            else {}
        )
        if error:
            media_health["error"] = str(error)
        if not healthy:
            critical.append(
                f"Media health endpoint {media_health_url} is not healthy"
            )
        warnings.extend(
            _media_metric_warnings(media_health["metrics"])
        )

    database_backend = str(database_backend or "sqlite").strip().lower()
    database = {
        "backend": database_backend,
        "path": str(database_path) if database_backend == "sqlite" else "",
        "exists": (
            database_path.is_file()
            if database_backend == "sqlite"
            else bool(database_url)
        ),
    }
    if database["exists"]:
        try:
            if database_backend == "postgres":
                database.update(_postgres_database_health(database_url))
            else:
                database["bytes"] = database_path.stat().st_size
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
        except Exception as error:
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
        "http_health": http_health,
        "media_health": media_health,
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
    parser.add_argument("--port", default=str(PORT))
    parser.add_argument("--http-health", default="")
    parser.add_argument("--media-health", default="")
    parser.add_argument(
        "--database-backend",
        default=os.environ.get("MESH_DATABASE_BACKEND", DATABASE_BACKEND),
    )
    parser.add_argument(
        "--database-url",
        default=os.environ.get("MESH_DATABASE_URL", DATABASE_URL),
    )
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
        http_health_url=args.http_health,
        media_health_url=args.media_health,
        database_backend=args.database_backend,
        database_url=args.database_url,
    )
    write_status(status, args.status_file)
    print(json.dumps(status, ensure_ascii=True, sort_keys=True))
    raise SystemExit(2 if status["status"] == "critical" else 0)


if __name__ == "__main__":
    main()
