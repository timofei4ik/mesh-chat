import argparse
import datetime as datetime_module
import hashlib
import json
import os
import sqlite3
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from server.config import DB_PATH  # noqa: E402
from server.persistence.postgres import (  # noqa: E402
    apply_postgres_migrations,
    connect_postgres,
)


TABLE_PRIORITY = (
    "accounts",
    "account_devices",
    "account_email_trusted_devices",
    "account_subscriptions",
    "subscription_orders",
    "subscription_events",
    "boosty_telegram_links",
    "service_sessions",
    "meshpro_usage",
    "ai_voice_transcriptions",
    "ai_image_ocr",
    "vpn_peers",
    "server_groups",
    "server_group_members",
    "server_group_keys",
    "file_transfer_sessions",
    "file_transfer_chunks",
)
IDENTITY_COLUMNS = {
    "offline_packets": "id",
    "subscription_events": "id",
    "sync_events": "event_id",
}
IGNORED_TABLES = {
    "schema_migrations",
    "sqlite_migration_progress",
    "sqlite_sequence",
}


def _source_tables(connection):
    names = {
        row[0]
        for row in connection.execute(
            """
            SELECT name FROM sqlite_master
            WHERE type='table' AND name NOT LIKE 'sqlite_%'
            """
        ).fetchall()
    }
    priority = [item for item in TABLE_PRIORITY if item in names]
    return priority + sorted(names.difference(priority))


def _source_columns(connection, table):
    rows = connection.execute(
        f'PRAGMA table_info("{table}")'
    ).fetchall()
    columns = [row[1] for row in rows]
    primary_key = [
        row[1]
        for row in sorted(rows, key=lambda item: item[5])
        if row[5]
    ]
    return columns, primary_key


def _target_columns(connection, table):
    with connection.cursor() as cursor:
        cursor.execute(
            """
            SELECT column_name
            FROM information_schema.columns
            WHERE table_schema=current_schema() AND table_name=%s
            ORDER BY ordinal_position
            """,
            (table,),
        )
        return [row[0] for row in cursor.fetchall()]


def _canonical_value(value):
    if isinstance(value, datetime_module.datetime):
        if value.tzinfo is not None:
            value = value.astimezone(
                datetime_module.timezone.utc
            ).replace(tzinfo=None)
        return value.isoformat(sep=" ", timespec="microseconds")
    if isinstance(value, datetime_module.date):
        return value.isoformat()
    if isinstance(value, memoryview):
        value = value.tobytes()
    if isinstance(value, bytes):
        return {"bytes": value.hex()}
    if isinstance(value, float):
        return format(value, ".17g")
    if isinstance(value, str):
        candidate = value.strip()
        if len(candidate) >= 19 and candidate[4:5] == "-":
            try:
                parsed = datetime_module.datetime.fromisoformat(
                    candidate.replace("Z", "+00:00")
                )
                return _canonical_value(parsed)
            except ValueError:
                pass
    return value


def _fingerprint(rows):
    digest = hashlib.sha256()
    for row in rows:
        payload = [_canonical_value(value) for value in row]
        digest.update(
            json.dumps(
                payload,
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            ).encode("utf-8")
        )
        digest.update(b"\n")
    return digest.hexdigest()


def _table_rows_sqlite(connection, table, columns, order_columns):
    selected = ", ".join(f'"{item}"' for item in columns)
    order = ", ".join(f'"{item}"' for item in order_columns or columns)
    return connection.execute(
        f'SELECT {selected} FROM "{table}" ORDER BY {order}'
    ).fetchall()


def _table_rows_postgres(connection, table, columns, order_columns):
    from psycopg import sql

    selected = sql.SQL(", ").join(map(sql.Identifier, columns))
    order = sql.SQL(", ").join(
        map(sql.Identifier, order_columns or columns)
    )
    statement = sql.SQL("SELECT {} FROM {} ORDER BY {}").format(
        selected,
        sql.Identifier(table),
        order,
    )
    with connection.cursor() as cursor:
        cursor.execute(statement)
        return cursor.fetchall()


def _upsert_statement(table, columns, primary_key):
    from psycopg import sql

    identifiers = list(map(sql.Identifier, columns))
    statement = sql.SQL("INSERT INTO {} ({}) VALUES ({})").format(
        sql.Identifier(table),
        sql.SQL(", ").join(identifiers),
        sql.SQL(", ").join(sql.Placeholder() for _ in columns),
    )
    if primary_key:
        updates = [
            sql.SQL("{}=EXCLUDED.{}").format(
                sql.Identifier(column),
                sql.Identifier(column),
            )
            for column in columns
            if column not in primary_key
        ]
        statement += sql.SQL(" ON CONFLICT ({}) ").format(
            sql.SQL(", ").join(map(sql.Identifier, primary_key))
        )
        if updates:
            statement += sql.SQL("DO UPDATE SET {}").format(
                sql.SQL(", ").join(updates)
            )
        else:
            statement += sql.SQL("DO NOTHING")
    else:
        statement += sql.SQL(" ON CONFLICT DO NOTHING")
    return statement


def _record_progress(
    connection,
    table,
    source_rows,
    copied_rows,
    source_fingerprint="",
    target_fingerprint="",
    status="copied",
):
    with connection.cursor() as cursor:
        cursor.execute(
            """
            INSERT INTO sqlite_migration_progress(
                source_table, source_rows, copied_rows,
                source_fingerprint, target_fingerprint, status, updated_at
            )
            VALUES(%s,%s,%s,%s,%s,%s,CURRENT_TIMESTAMP)
            ON CONFLICT(source_table) DO UPDATE SET
                source_rows=EXCLUDED.source_rows,
                copied_rows=EXCLUDED.copied_rows,
                source_fingerprint=EXCLUDED.source_fingerprint,
                target_fingerprint=EXCLUDED.target_fingerprint,
                status=EXCLUDED.status,
                updated_at=CURRENT_TIMESTAMP
            """,
            (
                table,
                source_rows,
                copied_rows,
                source_fingerprint,
                target_fingerprint,
                status,
            ),
        )


def copy_sqlite_to_postgres(sqlite_path, postgres_url, batch_size=500):
    source = sqlite3.connect(str(sqlite_path))
    target = connect_postgres(postgres_url)
    try:
        source.execute("PRAGMA foreign_keys=ON")
        apply_postgres_migrations(target)
        tables = _source_tables(source)
        for table in tables:
            if table in IGNORED_TABLES:
                continue
            source_columns, primary_key = _source_columns(source, table)
            target_columns = set(_target_columns(target, table))
            columns = [
                item for item in source_columns if item in target_columns
            ]
            if not columns:
                raise RuntimeError(
                    f"PostgreSQL table {table!r} is missing"
                )
            rows = _table_rows_sqlite(
                source,
                table,
                columns,
                primary_key,
            )
            statement = _upsert_statement(
                table,
                columns,
                primary_key,
            )
            with target.transaction():
                with target.cursor() as cursor:
                    for offset in range(0, len(rows), batch_size):
                        cursor.executemany(
                            statement,
                            rows[offset:offset + batch_size],
                        )
                _record_progress(
                    target,
                    table,
                    len(rows),
                    len(rows),
                )
            print(f"copied {table}: {len(rows)} rows")

        for table, column in IDENTITY_COLUMNS.items():
            if table not in tables:
                continue
            with target.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT setval(
                        pg_get_serial_sequence(%s, %s),
                        COALESCE((SELECT MAX({column}) FROM {table}), 1),
                        EXISTS(SELECT 1 FROM {table})
                    )
                    """.format(table=table, column=column),
                    (table, column),
                )
    finally:
        source.close()
        target.close()


def verify_sqlite_postgres(sqlite_path, postgres_url):
    source = sqlite3.connect(str(sqlite_path))
    target = connect_postgres(postgres_url)
    failures = []
    try:
        apply_postgres_migrations(target)
        for table in _source_tables(source):
            if table in IGNORED_TABLES:
                continue
            source_columns, primary_key = _source_columns(source, table)
            target_columns = set(_target_columns(target, table))
            columns = [
                item for item in source_columns if item in target_columns
            ]
            source_rows = _table_rows_sqlite(
                source,
                table,
                columns,
                primary_key,
            )
            target_rows = _table_rows_postgres(
                target,
                table,
                columns,
                primary_key,
            )
            source_fingerprint = _fingerprint(source_rows)
            target_fingerprint = _fingerprint(target_rows)
            matches = (
                len(source_rows) == len(target_rows)
                and source_fingerprint == target_fingerprint
            )
            _record_progress(
                target,
                table,
                len(source_rows),
                len(target_rows),
                source_fingerprint,
                target_fingerprint,
                "verified" if matches else "mismatch",
            )
            print(
                f"{'ok' if matches else 'MISMATCH'} {table}: "
                f"sqlite={len(source_rows)} postgres={len(target_rows)}"
            )
            if not matches:
                failures.append(table)
    finally:
        source.close()
        target.close()
    if failures:
        raise RuntimeError(
            "PostgreSQL parity failed for: " + ", ".join(failures)
        )


def main():
    parser = argparse.ArgumentParser(
        description="Copy and verify MeshChat SQLite data in PostgreSQL.",
    )
    parser.add_argument(
        "action",
        choices=("copy", "verify"),
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
    parser.add_argument("--batch-size", type=int, default=500)
    arguments = parser.parse_args()
    if not arguments.database_url:
        parser.error(
            "--database-url or MESH_DATABASE_URL is required"
        )
    if not arguments.sqlite_path.is_file():
        parser.error(
            f"SQLite database does not exist: {arguments.sqlite_path}"
        )

    if arguments.action == "copy":
        copy_sqlite_to_postgres(
            arguments.sqlite_path,
            arguments.database_url,
            batch_size=max(1, arguments.batch_size),
        )
    else:
        verify_sqlite_postgres(
            arguments.sqlite_path,
            arguments.database_url,
        )


if __name__ == "__main__":
    main()
