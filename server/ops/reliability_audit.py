from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import sqlite3
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from server.config import DB_PATH
from server.ops.backup_server import DEFAULT_BACKUP_DIR, resolve_path


DEFAULT_STATUS_PATH = Path(__file__).resolve().parents[2] / "data" / "reliability.json"


def _sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _table_exists(connection, table):
    return connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
        (table,),
    ).fetchone() is not None


def _audit_media(connection):
    checked_files = 0
    checked_chunks = 0
    problems = []

    for file_id, storage_path, expected_size, expected_sha256 in connection.execute(
        """
        SELECT file_id, storage_path, size_bytes, sha256
        FROM server_files
        WHERE COALESCE(storage_path, '') <> ''
        """
    ):
        checked_files += 1
        path = Path(storage_path)
        if not path.is_file():
            problems.append({"kind": "missing_file", "id": file_id, "path": str(path)})
            continue
        actual_size = path.stat().st_size
        if int(expected_size or 0) != actual_size:
            problems.append(
                {
                    "kind": "file_size_mismatch",
                    "id": file_id,
                    "expected": int(expected_size or 0),
                    "actual": actual_size,
                }
            )
        expected_digest = str(expected_sha256 or "").lower()
        if expected_digest:
            actual_digest = _sha256_file(path)
            if actual_digest != expected_digest:
                problems.append(
                    {
                        "kind": "file_checksum_mismatch",
                        "id": file_id,
                        "expected": expected_digest,
                        "actual": actual_digest,
                    }
                )

    for account, transfer_id, index, chunk_path, expected_size, expected_sha256 in connection.execute(
        """
        SELECT account_login, transfer_id, chunk_index, chunk_path,
               size_bytes, sha256
        FROM file_transfer_chunks
        ORDER BY account_login, transfer_id, chunk_index
        """
    ):
        checked_chunks += 1
        path = Path(chunk_path)
        item_id = f"{account}/{transfer_id}/{index}"
        if not path.is_file():
            problems.append({"kind": "missing_chunk", "id": item_id, "path": str(path)})
            continue
        actual_size = path.stat().st_size
        if int(expected_size or 0) != actual_size:
            problems.append(
                {
                    "kind": "chunk_size_mismatch",
                    "id": item_id,
                    "expected": int(expected_size or 0),
                    "actual": actual_size,
                }
            )
        expected_digest = str(expected_sha256 or "").lower()
        if expected_digest and _sha256_file(path) != expected_digest:
            problems.append({"kind": "chunk_checksum_mismatch", "id": item_id})

    completed_without_file = connection.execute(
        """
        SELECT COUNT(*)
        FROM file_transfer_sessions AS transfer
        WHERE transfer.status='complete'
          AND NOT EXISTS(
              SELECT 1 FROM server_files AS file
              WHERE file.file_id=transfer.file_id
          )
        """
    ).fetchone()[0]
    if completed_without_file:
        problems.append(
            {
                "kind": "completed_transfer_without_file",
                "count": completed_without_file,
            }
        )

    return {
        "checked_files": checked_files,
        "checked_chunks": checked_chunks,
        "problems": problems,
    }


def audit_database(database_path, verify_media=True):
    database_path = resolve_path(database_path)
    uri = f"{database_path.as_uri()}?mode=ro"
    connection = sqlite3.connect(uri, uri=True, timeout=30)
    try:
        quick_check = [row[0] for row in connection.execute("PRAGMA quick_check")]
        foreign_keys = [list(row) for row in connection.execute("PRAGMA foreign_key_check")]
        duplicate_operations = connection.execute(
            """
            SELECT COUNT(*) FROM (
                SELECT account_login, operation_id
                FROM sync_events
                WHERE operation_id <> ''
                GROUP BY account_login, operation_id
                HAVING COUNT(*) > 1
            )
            """
        ).fetchone()[0]
        invalid_cursors = connection.execute(
            """
            SELECT COUNT(*)
            FROM sync_cursors AS cursor
            WHERE cursor.cursor > COALESCE((
                SELECT MAX(event.event_id)
                FROM sync_events AS event
                WHERE event.account_login=cursor.account_login
            ), 0)
            """
        ).fetchone()[0]
        duplicate_reactions = connection.execute(
            """
            SELECT COUNT(*) FROM (
                SELECT scope, message_id, reactor_identity, reaction
                FROM server_reactions
                GROUP BY scope, message_id, reactor_identity, reaction
                HAVING COUNT(*) > 1
            )
            """
        ).fetchone()[0]
        result = {
            "path": str(database_path),
            "bytes": database_path.stat().st_size,
            "quick_check": quick_check,
            "foreign_key_violations": foreign_keys,
            "duplicate_operations": duplicate_operations,
            "invalid_sync_cursors": invalid_cursors,
            "duplicate_reactions": duplicate_reactions,
        }
        if verify_media and _table_exists(connection, "server_files"):
            result["media"] = _audit_media(connection)
        return result
    finally:
        connection.close()


def audit_latest_backup(backup_dir):
    backup_dir = resolve_path(backup_dir)
    backups = sorted(
        backup_dir.glob("server-*.db.gz"),
        key=lambda item: item.stat().st_mtime,
        reverse=True,
    )
    if not backups:
        return {"found": False, "problems": ["no backup found"]}

    backup = backups[0]
    problems = []
    checksum_path = backup.with_suffix(backup.suffix + ".sha256")
    metadata_path = backup.with_suffix(backup.suffix + ".json")
    actual_checksum = _sha256_file(backup)
    expected_checksum = ""
    if checksum_path.is_file():
        expected_checksum = checksum_path.read_text(encoding="ascii").split()[0].lower()
        if expected_checksum != actual_checksum:
            problems.append("backup checksum mismatch")
    else:
        problems.append("backup checksum sidecar is missing")
    if not metadata_path.is_file():
        problems.append("backup metadata sidecar is missing")
    else:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        if str(metadata.get("sha256") or "").lower() != actual_checksum:
            problems.append("backup metadata checksum mismatch")

    integrity = []
    try:
        with tempfile.TemporaryDirectory() as temp_dir:
            restored = Path(temp_dir) / "restored.db"
            with gzip.open(backup, "rb") as source, restored.open("wb") as target:
                for block in iter(lambda: source.read(1024 * 1024), b""):
                    target.write(block)
            connection = sqlite3.connect(restored)
            try:
                integrity = [row[0] for row in connection.execute("PRAGMA integrity_check")]
            finally:
                connection.close()
        if integrity != ["ok"]:
            problems.append("restored backup integrity_check failed")
    except (OSError, EOFError, sqlite3.Error) as error:
        problems.append(f"backup restore failed: {error}")

    modified = datetime.fromtimestamp(backup.stat().st_mtime, timezone.utc)
    return {
        "found": True,
        "path": str(backup),
        "bytes": backup.stat().st_size,
        "age_hours": round(
            (datetime.now(timezone.utc) - modified).total_seconds() / 3600,
            2,
        ),
        "sha256": actual_checksum,
        "integrity_check": integrity,
        "problems": problems,
    }


def collect_reliability(database_path, backup_dir, verify_media=True):
    critical = []
    warnings = []
    try:
        database = audit_database(database_path, verify_media=verify_media)
        if database["quick_check"] != ["ok"]:
            critical.append("database quick_check failed")
        if database["foreign_key_violations"]:
            critical.append("database has foreign key violations")
        if database["duplicate_operations"]:
            critical.append("sync event journal contains duplicate operations")
        if database["invalid_sync_cursors"]:
            critical.append("sync cursor points beyond the event journal")
        if database["duplicate_reactions"]:
            critical.append("reaction uniqueness invariant failed")
        media = database.get("media") or {}
        if media.get("problems"):
            critical.append(f"media integrity failed for {len(media['problems'])} item(s)")
    except (OSError, sqlite3.Error, json.JSONDecodeError) as error:
        database = {"path": str(resolve_path(database_path)), "error": str(error)}
        critical.append(f"database audit failed: {error}")

    try:
        backup = audit_latest_backup(backup_dir)
        if backup.get("problems"):
            critical.extend(backup["problems"])
        if backup.get("found") and backup.get("age_hours", 0) > 36:
            warnings.append("latest backup is older than 36 hours")
    except (OSError, sqlite3.Error, json.JSONDecodeError) as error:
        backup = {"error": str(error)}
        critical.append(f"backup audit failed: {error}")

    return {
        "checked_at": datetime.now(timezone.utc).isoformat(),
        "status": "critical" if critical else "warning" if warnings else "ok",
        "critical": critical,
        "warnings": warnings,
        "database": database,
        "backup": backup,
    }


def write_report(report, path):
    path = resolve_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)
    try:
        path.chmod(0o600)
    except OSError:
        pass


def main():
    parser = argparse.ArgumentParser(description="Audit MeshChat persistence reliability")
    parser.add_argument("--database", default=os.environ.get("MESH_SERVER_DB", str(DB_PATH)))
    parser.add_argument(
        "--backup-dir",
        default=os.environ.get("MESH_BACKUP_DIR", str(DEFAULT_BACKUP_DIR)),
    )
    parser.add_argument(
        "--status-file",
        default=os.environ.get("MESH_RELIABILITY_STATUS", str(DEFAULT_STATUS_PATH)),
    )
    parser.add_argument("--no-media", action="store_true")
    args = parser.parse_args()
    report = collect_reliability(
        args.database,
        args.backup_dir,
        verify_media=not args.no_media,
    )
    write_report(report, args.status_file)
    print(json.dumps(report, ensure_ascii=True, sort_keys=True))
    raise SystemExit(2 if report["status"] == "critical" else 0)


if __name__ == "__main__":
    main()
