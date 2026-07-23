import re
from contextlib import contextmanager, nullcontext
from datetime import date, datetime, time
from pathlib import Path

from .postgres_billing import PostgresBillingRepository
from .sqlite import (
    SQLiteIdentityRepository,
    SQLiteSubscriptionRepository,
)


_REPLACE_CONFLICT_KEYS = {
    "server_groups": ("group_id",),
    "server_group_members": ("group_id", "node_id"),
    "server_chat_deletes": (
        "owner_node",
        "peer_node",
        "chat_kind",
        "chat_id",
    ),
}


def _normalize_postgres_value(value):
    if isinstance(value, datetime):
        return value.isoformat(sep=" ")
    if isinstance(value, (date, time)):
        return value.isoformat()
    return value


def _normalize_postgres_row(row):
    if row is None:
        return None
    return tuple(_normalize_postgres_value(value) for value in row)


def _replace_qmark_placeholders(query):
    result = []
    quote = None
    index = 0
    while index < len(query):
        character = query[index]
        if quote:
            result.append(character)
            if character == quote:
                if index + 1 < len(query) and query[index + 1] == quote:
                    result.append(query[index + 1])
                    index += 1
                else:
                    quote = None
        elif character in {"'", '"'}:
            quote = character
            result.append(character)
        elif character == "?":
            result.append("%s")
        else:
            result.append(character)
        index += 1
    return "".join(result)


def _replace_scalar_max(query):
    result = []
    index = 0
    upper = query.upper()
    while index < len(query):
        start = upper.find("MAX(", index)
        if start < 0:
            result.append(query[index:])
            break
        result.append(query[index:start])
        cursor = start + 4
        depth = 1
        quote = None
        has_top_level_comma = False
        while cursor < len(query) and depth:
            character = query[cursor]
            if quote:
                if character == quote:
                    if (
                        cursor + 1 < len(query)
                        and query[cursor + 1] == quote
                    ):
                        cursor += 1
                    else:
                        quote = None
            elif character in {"'", '"'}:
                quote = character
            elif character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
            elif character == "," and depth == 1:
                has_top_level_comma = True
            cursor += 1
        if not depth and has_top_level_comma:
            result.append("GREATEST(")
        else:
            result.append(query[start:start + 4])
        result.append(query[start + 4:cursor])
        index = cursor
    return "".join(result)


def _translate_insert_mode(query):
    ignored = re.match(
        r"(?is)^(\s*)INSERT\s+OR\s+IGNORE\s+INTO\s+",
        query,
    )
    replaced = re.match(
        r"(?is)^(\s*)INSERT\s+OR\s+REPLACE\s+INTO\s+"
        r"([A-Za-z_][A-Za-z0-9_]*)\s*\((.*?)\)\s*"
        r"VALUES\s*\((.*)\)\s*$",
        query.strip().rstrip(";"),
    )
    capture_identity = False
    if ignored:
        query = re.sub(
            r"(?is)^(\s*)INSERT\s+OR\s+IGNORE\s+INTO\s+",
            r"\1INSERT INTO ",
            query,
            count=1,
        ).strip().rstrip(";")
        capture_identity = bool(
            re.match(r"(?is)^INSERT\s+INTO\s+sync_events\b", query)
        )
        query += " ON CONFLICT DO NOTHING"
        if capture_identity:
            query += " RETURNING event_id"
        return query, capture_identity
    if not replaced:
        return query, False

    table = replaced.group(2).lower()
    conflict_keys = _REPLACE_CONFLICT_KEYS.get(table)
    if not conflict_keys:
        raise RuntimeError(
            f"PostgreSQL replacement conflict key is unknown for {table}"
        )
    columns = [
        item.strip()
        for item in replaced.group(3).split(",")
    ]
    assignments = [
        f"{column}=EXCLUDED.{column}"
        for column in columns
        if column.lower() not in conflict_keys
    ]
    normalized = (
        f"INSERT INTO {table}({', '.join(columns)}) "
        f"VALUES({replaced.group(4)}) "
        f"ON CONFLICT({', '.join(conflict_keys)}) DO UPDATE SET "
        f"{', '.join(assignments)}"
    )
    return normalized, False


def _qualify_upsert_target_columns(query):
    match = re.match(
        r"(?is)^\s*INSERT\s+INTO\s+"
        r"([A-Za-z_][A-Za-z0-9_]*)\s*\((.*?)\)\s*"
        r"VALUES\s*\(.*?\)\s+ON\s+CONFLICT\b.*?"
        r"\bDO\s+UPDATE\s+SET\s+(.*)$",
        query,
    )
    if not match:
        return query

    table = match.group(1)
    columns = {
        item.strip().lower()
        for item in match.group(2).split(",")
        if item.strip()
    }
    update_start = match.start(3)
    update_clause = query[update_start:]
    token_pattern = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*\b")
    pieces = []
    cursor = 0

    for token in token_pattern.finditer(update_clause):
        pieces.append(update_clause[cursor:token.start()])
        value = token.group(0)
        before = update_clause[:token.start()].rstrip()
        after = update_clause[token.end():].lstrip()
        is_qualified = bool(before) and before[-1] == "."
        is_assignment_target = after.startswith("=")
        is_function = after.startswith("(")
        if (
            value.lower() in columns
            and not is_qualified
            and not is_assignment_target
            and not is_function
        ):
            pieces.append(f"{table}.{value}")
        else:
            pieces.append(value)
        cursor = token.end()
    pieces.append(update_clause[cursor:])
    return query[:update_start] + "".join(pieces)


def translate_sqlite_query(query):
    translated = str(query)
    translated = re.sub(
        r"(?is)STRFTIME\(\s*'%Y-%m-%d %H:%M:%f'\s*,\s*'now'\s*\)",
        "CURRENT_TIMESTAMP",
        translated,
    )
    translated = re.sub(
        r"(?is)DATETIME\(\s*'now'\s*,\s*(%s|\?)\s*\)",
        r"(CURRENT_TIMESTAMP + CAST(\1 AS INTERVAL))",
        translated,
    )
    translated = re.sub(
        r"(?is)DATETIME\(\s*(CASE\b.*?\bEND)\s*,\s*(%s|\?)\s*\)",
        r"(\1 + CAST(\2 AS INTERVAL))",
        translated,
    )
    translated = re.sub(
        r"(?is)DATETIME\(\s*'now'\s*,\s*('(?:[^']|'')*')\s*\)",
        r"(CURRENT_TIMESTAMP + INTERVAL \1)",
        translated,
    )
    translated = re.sub(
        r"(?is)DATETIME\(\s*'now'\s*\)",
        "CURRENT_TIMESTAMP",
        translated,
    )
    translated = re.sub(
        r"(?is)DATETIME\(\s*([A-Za-z_][A-Za-z0-9_.]*)\s*\)",
        r"\1",
        translated,
    )
    translated = re.sub(
        r"(?is)strftime\(\s*'%s'\s*,\s*'now'\s*\)\s*-\s*"
        r"strftime\(\s*'%s'\s*,\s*created_at\s*\)",
        "EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - created_at))",
        translated,
    )
    translated = re.sub(
        r"(?is)\(\s*JULIANDAY\(next_key_at\)\s*-\s*"
        r"JULIANDAY\(\s*'now'\s*\)\s*\)\s*\*\s*86400",
        "EXTRACT(EPOCH FROM (next_key_at - CURRENT_TIMESTAMP))",
        translated,
    )
    translated = _replace_qmark_placeholders(translated)
    translated = _replace_scalar_max(translated)
    translated, capture_identity = _translate_insert_mode(translated)
    translated = _qualify_upsert_target_columns(translated)
    return translated, capture_identity


class PostgresCompatibilityCursor:
    def __init__(self, cursor, *, lastrowid=None):
        self._cursor = cursor
        self.lastrowid = lastrowid

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()
        return False

    @property
    def rowcount(self):
        return self._cursor.rowcount

    def execute(self, query, parameters=()):
        translated, capture_identity = translate_sqlite_query(query)
        self._cursor.execute(translated, parameters)
        self.lastrowid = None
        if capture_identity:
            row = self._cursor.fetchone()
            self.lastrowid = row[0] if row else None
        return self

    def executemany(self, query, parameters):
        translated, capture_identity = translate_sqlite_query(query)
        if capture_identity:
            raise RuntimeError(
                "executemany cannot capture PostgreSQL identities"
            )
        self._cursor.executemany(translated, parameters)
        self.lastrowid = None
        return self

    def fetchone(self):
        return _normalize_postgres_row(self._cursor.fetchone())

    def fetchall(self):
        return [
            _normalize_postgres_row(row)
            for row in self._cursor.fetchall()
        ]

    def __iter__(self):
        return (
            _normalize_postgres_row(row)
            for row in self._cursor
        )

    def close(self):
        self._cursor.close()


class PostgresCompatibilityConnection:
    """DB-API facade for the legacy storage methods during PostgreSQL cutover."""

    def __init__(self, connection):
        self.raw_connection = connection
        self._transaction_depth = 0

    @property
    def in_transaction(self):
        try:
            from psycopg.pq import TransactionStatus

            return (
                self.raw_connection.info.transaction_status
                != TransactionStatus.IDLE
            )
        except (ImportError, AttributeError):
            return False

    def execute(self, query, parameters=()):
        return self.cursor().execute(query, parameters)

    def executemany(self, query, parameters):
        return self.cursor().executemany(query, parameters)

    def cursor(self):
        return PostgresCompatibilityCursor(
            self.raw_connection.cursor()
        )

    @contextmanager
    def transaction(self):
        self._transaction_depth += 1
        try:
            with self.raw_connection.transaction():
                yield self
        finally:
            self._transaction_depth -= 1

    def commit(self):
        if self._transaction_depth:
            return
        self.raw_connection.commit()

    def rollback(self):
        if self._transaction_depth:
            return
        self.raw_connection.rollback()

    def close(self):
        self.raw_connection.close()


def connect_postgres(database_url):
    try:
        import psycopg
    except ModuleNotFoundError as error:
        raise RuntimeError(
            "PostgreSQL requires psycopg[binary] from server/requirements.txt"
        ) from error
    return psycopg.connect(database_url, autocommit=True)


def apply_postgres_migrations(connection, migration_dir=None):
    directory = Path(
        migration_dir
        or Path(__file__).with_name("postgres_migrations")
    )
    with connection.transaction():
        with connection.cursor() as cursor:
            cursor.execute(
                """
                CREATE TABLE IF NOT EXISTS schema_migrations(
                    version TEXT PRIMARY KEY,
                    applied_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
                )
                """
            )
            cursor.execute("SELECT version FROM schema_migrations")
            applied = {row[0] for row in cursor.fetchall()}
            for path in sorted(directory.glob("*.sql")):
                if path.stem in applied:
                    continue
                cursor.execute(
                    path.read_text(encoding="utf-8"),
                    prepare=False,
                )
                cursor.execute(
                    "INSERT INTO schema_migrations(version) VALUES(%s)",
                    (path.stem,),
                )


class PostgresBillingUnitOfWork:
    def __init__(self, connection, *, write=False):
        self._connection = connection
        self._write = bool(write)
        self._transaction = None
        self.billing = PostgresBillingRepository(connection)

    def __enter__(self):
        self._transaction = (
            self._connection.transaction()
            if self._write
            else nullcontext()
        )
        self._transaction.__enter__()
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return self._transaction.__exit__(
            exc_type,
            exc_value,
            traceback,
        )

    def commit(self):
        return None

    def rollback(self):
        if self._write:
            self._connection.rollback()


class PostgresBillingUnitOfWorkFactory:
    def __init__(self, connection):
        self._connection = connection

    def __call__(self, *, write=False):
        return PostgresBillingUnitOfWork(
            self._connection,
            write=write,
        )


class PostgresUnitOfWork:
    def __init__(self, connection, *, write=False):
        self._connection = connection
        self._write = bool(write)
        self._transaction = None
        self.identity = SQLiteIdentityRepository(connection)
        self.subscriptions = SQLiteSubscriptionRepository(connection)
        self.billing = PostgresBillingRepository(
            connection.raw_connection
        )

    def __enter__(self):
        self._transaction = (
            self._connection.transaction()
            if self._write
            else nullcontext()
        )
        self._transaction.__enter__()
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return self._transaction.__exit__(
            exc_type,
            exc_value,
            traceback,
        )

    def commit(self):
        return None

    def rollback(self):
        if self._write:
            self._connection.rollback()


class PostgresUnitOfWorkFactory:
    def __init__(self, connection):
        self._connection = connection

    def __call__(self, *, write=False):
        return PostgresUnitOfWork(
            self._connection,
            write=write,
        )
