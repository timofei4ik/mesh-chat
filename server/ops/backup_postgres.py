from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import unquote, urlparse

try:
    import fcntl
except ImportError:  # pragma: no cover - only used by Linux deployment
    fcntl = None


ROOT_DIR = Path(__file__).resolve().parents[2]

if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))

from server.ops.backup_server import (  # noqa: E402
    DEFAULT_BACKUP_DIR,
    DEFAULT_KEEP,
    resolve_path,
    sha256_file,
)


def _connection_arguments(database_url):
    parsed = urlparse(database_url)
    if parsed.scheme not in {"postgres", "postgresql"}:
        raise ValueError("MESH_DATABASE_URL must be a PostgreSQL URL")
    database = unquote(parsed.path.lstrip("/"))
    if not parsed.hostname or not parsed.username or not database:
        raise ValueError("PostgreSQL URL is missing host, user, or database")
    return {
        "host": parsed.hostname,
        "port": str(parsed.port or 5432),
        "user": unquote(parsed.username),
        "password": unquote(parsed.password or ""),
        "database": database,
    }


def _prune_backups(backup_dir, keep):
    backups = sorted(
        Path(backup_dir).glob("server-*.pgdump"),
        key=lambda item: item.name,
        reverse=True,
    )
    removed = []
    for backup in backups[max(keep, 1):]:
        for related in (
            backup,
            backup.with_suffix(backup.suffix + ".sha256"),
            backup.with_suffix(backup.suffix + ".json"),
        ):
            related.unlink(missing_ok=True)
        removed.append(backup.name)
    return removed


def create_postgres_backup(
    database_url,
    backup_dir,
    keep=DEFAULT_KEEP,
    now=None,
):
    connection = _connection_arguments(database_url)
    backup_dir = resolve_path(backup_dir)
    backup_dir.mkdir(parents=True, exist_ok=True)
    timestamp = now or datetime.now(timezone.utc)
    stamp = timestamp.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    final_path = backup_dir / f"server-{stamp}.pgdump"
    temporary = backup_dir / f".{final_path.name}.tmp"
    checksum_path = final_path.with_suffix(final_path.suffix + ".sha256")
    metadata_path = final_path.with_suffix(final_path.suffix + ".json")
    lock_path = backup_dir / ".backup.lock"
    environment = os.environ.copy()
    environment["PGPASSWORD"] = connection["password"]

    with lock_path.open("a+b") as lock_file:
        if fcntl is not None:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        temporary.unlink(missing_ok=True)
        try:
            subprocess.run(
                [
                    "pg_dump",
                    "--format=custom",
                    "--no-owner",
                    "--no-acl",
                    "--host",
                    connection["host"],
                    "--port",
                    connection["port"],
                    "--username",
                    connection["user"],
                    "--file",
                    str(temporary),
                    connection["database"],
                ],
                check=True,
                env=environment,
                capture_output=True,
                text=True,
            )
            subprocess.run(
                ["pg_restore", "--list", str(temporary)],
                check=True,
                capture_output=True,
                text=True,
            )
            os.replace(temporary, final_path)
            checksum = sha256_file(final_path)
            checksum_path.write_text(
                f"{checksum}  {final_path.name}\n",
                encoding="ascii",
            )
            metadata = {
                "backend": "postgres",
                "backup": final_path.name,
                "backup_bytes": final_path.stat().st_size,
                "created_at": timestamp.astimezone(timezone.utc).isoformat(),
                "database": connection["database"],
                "host": connection["host"],
                "integrity": "pg_restore-list-ok",
                "sha256": checksum,
            }
            metadata_path.write_text(
                json.dumps(metadata, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            for protected in (final_path, checksum_path, metadata_path):
                protected.chmod(0o600)
            removed = _prune_backups(backup_dir, keep)
            return {
                **metadata,
                "path": str(final_path),
                "removed": removed,
                "retained": len(list(backup_dir.glob("server-*.pgdump"))),
            }
        finally:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(
        description="Back up the MeshChat PostgreSQL database",
    )
    parser.add_argument(
        "--database-url",
        default=os.environ.get("MESH_DATABASE_URL", "").strip(),
    )
    parser.add_argument(
        "--backup-dir",
        default=os.environ.get("MESH_BACKUP_DIR", str(DEFAULT_BACKUP_DIR)),
    )
    parser.add_argument(
        "--keep",
        type=int,
        default=int(os.environ.get("MESH_BACKUP_KEEP", str(DEFAULT_KEEP))),
    )
    arguments = parser.parse_args()
    if not arguments.database_url:
        parser.error("--database-url or MESH_DATABASE_URL is required")
    result = create_postgres_backup(
        arguments.database_url,
        arguments.backup_dir,
        arguments.keep,
    )
    print(json.dumps(result, ensure_ascii=True, sort_keys=True))


if __name__ == "__main__":
    main()
