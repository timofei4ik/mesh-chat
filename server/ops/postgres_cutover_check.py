import argparse
import os
import sqlite3
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from server.config import DB_PATH  # noqa: E402
from server.ops.sqlite_to_postgres import (  # noqa: E402
    verify_sqlite_postgres,
)
from server.persistence.postgres import (  # noqa: E402
    apply_postgres_migrations,
    connect_postgres,
)


def check_sqlite_integrity(sqlite_path):
    connection = sqlite3.connect(str(sqlite_path))
    try:
        result = connection.execute("PRAGMA integrity_check").fetchone()
    finally:
        connection.close()
    if not result or str(result[0]).lower() != "ok":
        raise RuntimeError(
            f"SQLite integrity check failed: {result!r}"
        )


def check_postgres_migrations(postgres_url):
    connection = connect_postgres(postgres_url)
    try:
        apply_postgres_migrations(connection)
        expected = {
            path.stem
            for path in (
                Path(__file__).resolve().parents[1]
                / "persistence"
                / "postgres_migrations"
            ).glob("*.sql")
        }
        with connection.cursor() as cursor:
            cursor.execute("SELECT version FROM schema_migrations")
            applied = {row[0] for row in cursor.fetchall()}
    finally:
        connection.close()
    missing = expected.difference(applied)
    if missing:
        raise RuntimeError(
            "PostgreSQL migrations are missing: "
            + ", ".join(sorted(missing))
        )


def main():
    parser = argparse.ArgumentParser(
        description="Run the final SQLite-to-PostgreSQL cutover checks.",
    )
    parser.add_argument(
        "--sqlite-path",
        type=Path,
        default=DB_PATH,
    )
    parser.add_argument(
        "--database-url",
        default=os.environ.get("MESH_DATABASE_URL", "").strip(),
    )
    arguments = parser.parse_args()
    if not arguments.database_url:
        parser.error(
            "--database-url or MESH_DATABASE_URL is required"
        )
    if not arguments.sqlite_path.is_file():
        parser.error(
            f"SQLite database does not exist: {arguments.sqlite_path}"
        )

    check_sqlite_integrity(arguments.sqlite_path)
    print("ok SQLite integrity")
    check_postgres_migrations(arguments.database_url)
    print("ok PostgreSQL migrations")
    verify_sqlite_postgres(
        arguments.sqlite_path,
        arguments.database_url,
    )
    print("CUTOVER READY: database contents match exactly")


if __name__ == "__main__":
    main()
