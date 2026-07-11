from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import shutil
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    import fcntl
except ImportError:  # pragma: no cover - only used by Linux deployment
    fcntl = None


ROOT_DIR = Path(__file__).resolve().parents[2]

if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))

from server.config import DB_PATH


DEFAULT_BACKUP_DIR = ROOT_DIR / "backups" / "automatic"
DEFAULT_KEEP = 7


def resolve_path(path):
    resolved = Path(path)
    if not resolved.is_absolute():
        resolved = ROOT_DIR / resolved
    return resolved.resolve()


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def prune_backups(backup_dir, keep):
    backup_dir = Path(backup_dir)
    backups = sorted(
        backup_dir.glob("server-*.db.gz"),
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
            if related.exists():
                related.unlink()
        removed.append(backup.name)
    return removed


def create_backup(source_path, backup_dir, keep=DEFAULT_KEEP, now=None):
    source_path = resolve_path(source_path)
    backup_dir = resolve_path(backup_dir)
    backup_dir.mkdir(parents=True, exist_ok=True)

    if not source_path.is_file():
        raise FileNotFoundError(f"Server database not found: {source_path}")

    timestamp = now or datetime.now(timezone.utc)
    stamp = timestamp.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    filename = f"server-{stamp}.db.gz"
    final_path = backup_dir / filename
    checksum_path = final_path.with_suffix(final_path.suffix + ".sha256")
    metadata_path = final_path.with_suffix(final_path.suffix + ".json")
    temp_db = backup_dir / f".{filename}.tmp.db"
    temp_gzip = backup_dir / f".{filename}.tmp.gz"
    lock_path = backup_dir / ".backup.lock"

    with lock_path.open("a+b") as lock_file:
        if fcntl is not None:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)

        for temporary in (temp_db, temp_gzip):
            temporary.unlink(missing_ok=True)

        source = None
        target = None
        try:
            source_uri = f"{source_path.as_uri()}?mode=ro"
            source = sqlite3.connect(source_uri, uri=True, timeout=30)
            target = sqlite3.connect(temp_db)
            source.backup(target, pages=2048, sleep=0.02)
            integrity_rows = target.execute("PRAGMA integrity_check").fetchall()
            if integrity_rows != [("ok",)]:
                raise RuntimeError(f"Backup integrity check failed: {integrity_rows}")
            target.close()
            target = None
            source.close()
            source = None

            with temp_db.open("rb") as raw_source:
                with gzip.open(temp_gzip, "wb", compresslevel=6) as compressed:
                    shutil.copyfileobj(raw_source, compressed, length=1024 * 1024)

            os.replace(temp_gzip, final_path)
            checksum = sha256_file(final_path)
            checksum_temp = checksum_path.with_suffix(checksum_path.suffix + ".tmp")
            checksum_temp.write_text(
                f"{checksum}  {final_path.name}\n",
                encoding="ascii",
            )
            os.replace(checksum_temp, checksum_path)

            metadata = {
                "created_at": timestamp.astimezone(timezone.utc).isoformat(),
                "source": str(source_path),
                "source_bytes": source_path.stat().st_size,
                "backup": final_path.name,
                "backup_bytes": final_path.stat().st_size,
                "sha256": checksum,
                "integrity": "ok",
            }
            metadata_temp = metadata_path.with_suffix(metadata_path.suffix + ".tmp")
            metadata_temp.write_text(
                json.dumps(metadata, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            os.replace(metadata_temp, metadata_path)

            for protected_path in (final_path, checksum_path, metadata_path):
                try:
                    protected_path.chmod(0o600)
                except OSError:
                    pass

            removed = prune_backups(backup_dir, keep)
            return {
                **metadata,
                "path": str(final_path),
                "removed": removed,
                "retained": len(list(backup_dir.glob("server-*.db.gz"))),
            }
        finally:
            if target is not None:
                target.close()
            if source is not None:
                source.close()
            temp_db.unlink(missing_ok=True)
            temp_gzip.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description="Back up the MeshChat SQLite database")
    parser.add_argument(
        "--database",
        default=os.environ.get("MESH_SERVER_DB", str(DB_PATH)),
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
    args = parser.parse_args()
    result = create_backup(args.database, args.backup_dir, args.keep)
    print(json.dumps(result, ensure_ascii=True, sort_keys=True))


if __name__ == "__main__":
    main()
