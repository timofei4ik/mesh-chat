import json
import sqlite3
from datetime import datetime, timezone

from server.config import DATABASE_BACKEND, DATABASE_URL, DB_PATH
from server.persistence import connect_postgres


def _parse(value):
    if isinstance(value, (int, float)):
        seconds = float(value)
        if abs(seconds) >= 100_000_000_000:
            seconds /= 1000
        return datetime.fromtimestamp(seconds, timezone.utc)
    raw = str(value or "").strip()
    if not raw:
        return None
    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def main():
    connection = (
        connect_postgres(DATABASE_URL)
        if DATABASE_BACKEND == "postgres"
        else sqlite3.connect(DB_PATH)
    )
    try:
        events = connection.execute(
            """
            SELECT packet_type, payload_json
            FROM sync_events
            WHERE packet_type IN ('chat_message', 'group_message', 'file_chunk')
            """
        ).fetchall()
        recoverable = {}
        for packet_type, raw_payload in events:
            try:
                payload = json.loads(raw_payload or "{}")
            except (TypeError, ValueError, json.JSONDecodeError):
                continue
            created_at = next(
                (
                    _parse(payload.get(key))
                    for key in ("created_at", "timestamp", "sent_at", "time", "date")
                    if payload.get(key) not in (None, "")
                ),
                None,
            )
            message_id = str(
                payload.get("group_message_id")
                or payload.get("packet_id")
                or payload.get("file_id")
                or ""
            ).strip()
            if message_id and created_at is not None:
                recoverable[(packet_type, message_id)] = created_at

        mismatched = 0
        checked = 0
        for (packet_type, message_id), original in recoverable.items():
            table = {
                "chat_message": "direct_messages",
                "group_message": "server_group_messages",
                "file_chunk": "server_files",
            }[packet_type]
            id_column = "file_id" if packet_type == "file_chunk" else "message_id"
            placeholder = "%s" if DATABASE_BACKEND == "postgres" else "?"
            row = connection.execute(
                f"SELECT created_at FROM {table} WHERE {id_column}={placeholder}",
                (message_id,),
            ).fetchone()
            if not row:
                continue
            stored = _parse(row[0])
            if stored is None:
                continue
            checked += 1
            if abs((stored - original).total_seconds()) >= 60:
                mismatched += 1

        print(
            json.dumps(
                {
                    "backend": DATABASE_BACKEND,
                    "recoverable_events": len(recoverable),
                    "stored_rows_checked": checked,
                    "timestamps_off_by_at_least_60s": mismatched,
                },
                sort_keys=True,
            )
        )
    finally:
        connection.close()


if __name__ == "__main__":
    main()
