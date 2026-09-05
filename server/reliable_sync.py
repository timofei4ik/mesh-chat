"""Compact delivery intents; history and its ordered journal own message data."""
import time

from server.account_deletion import AccountDataPolicy


RELIABLE_SYNC_TYPES = frozenset({
    "chat_message", "group_message", "message_edit", "group_message_edit",
    "message_delete", "group_message_delete", "chat_delete", "group_delete",
})


class DeliveryCapacityError(RuntimeError):
    pass


class SyncDeliveryQueue:
    def __init__(self, db, max_accounts=100000, retention_seconds=7 * 86400):
        self.db = db
        self.max_accounts = max(1, int(max_accounts))
        self.retention_seconds = max(60, int(retention_seconds))
        if hasattr(db, "raw_connection"):
            with db.transaction():
                db.execute("SELECT pg_advisory_xact_lock(?)", (0x4D455349,))
                self._schema()
        else:
            self._schema()

    def _schema(self):
        self.db.execute("""CREATE TABLE IF NOT EXISTS realtime_sync_outbox(
            account_login TEXT PRIMARY KEY,
            target_cursor BIGINT NOT NULL,
            updated_at DOUBLE PRECISION NOT NULL
        )""")
        self.db.execute("""CREATE INDEX IF NOT EXISTS idx_realtime_sync_age
            ON realtime_sync_outbox(updated_at)""")
        self.db.commit()

    def stage(self, login, cursor):
        # The caller owns the same transaction as history/journal persistence.
        if not self.db.in_transaction:
            raise RuntimeError("Delivery staging requires the history transaction")
        if not login or len(login) > 256 or cursor <= 0:
            raise ValueError("Invalid delivery identity or cursor")
        self.lock()
        exists = self.db.execute(
            "SELECT 1 FROM realtime_sync_outbox WHERE account_login=?", (login,)
        ).fetchone()
        if not exists:
            count = self.db.execute("SELECT COUNT(*) FROM realtime_sync_outbox").fetchone()[0]
            if count >= self.max_accounts:
                self.prune(limit=256)
                count = self.db.execute("SELECT COUNT(*) FROM realtime_sync_outbox").fetchone()[0]
                if count >= self.max_accounts:
                    raise DeliveryCapacityError("Reliable delivery account limit reached")
        self.db.execute("""INSERT INTO realtime_sync_outbox VALUES(?,?,?)
            ON CONFLICT(account_login) DO UPDATE SET
                target_cursor=MAX(realtime_sync_outbox.target_cursor, excluded.target_cursor),
                updated_at=excluded.updated_at
        """, (login, int(cursor), time.time()))

    def lock(self):
        # Acquire before history/journal row locks as well as before admission.
        # A consistent lock order prevents overlapping account sets deadlocking.
        if hasattr(self.db, "raw_connection"):
            self.db.execute("SELECT pg_advisory_xact_lock(?)", (0x4D45534A,))

    def pending_cursor(self, login, node_id):
        # Journal state survives compact-intent expiry. An old offline device
        # still recovers through delta/snapshot; pruning never deletes history.
        row = self.db.execute("""SELECT s.latest_cursor, COALESCE(c.cursor, 0)
            FROM sync_event_state s LEFT JOIN sync_cursors c
            ON c.account_login=s.account_login AND c.node_id=?
            WHERE s.account_login=?
        """, (node_id, login)).fetchone()
        return int(row[0]) if row and int(row[0]) > int(row[1]) else 0

    def prune(self, limit=256):
        cutoff = time.time() - self.retention_seconds
        rows = self.db.execute("""SELECT account_login FROM realtime_sync_outbox
            WHERE updated_at<? ORDER BY updated_at LIMIT ?
        """, (cutoff, min(256, max(1, int(limit))))).fetchall()
        removed = 0
        for (login,) in rows:
            removed += self.db.execute("""DELETE FROM realtime_sync_outbox
                WHERE account_login=? AND updated_at<?
            """, (login, cutoff)).rowcount
        return removed

    def stats(self):
        row = self.db.execute("SELECT COUNT(*), MIN(updated_at) FROM realtime_sync_outbox").fetchone()
        return {
            "delivery_intent_accounts": int(row[0]),
            "delivery_intent_oldest_seconds": max(0, time.time() - row[1]) if row[1] else 0,
        }


class SyncDeliveryDeletionOwner:
    name = "reliable_sync"
    policies = (AccountDataPolicy(name, "realtime_sync_outbox"),)

    def __init__(self, db):
        self.db = db

    def delete_account(self, context):
        self.db.execute("DELETE FROM realtime_sync_outbox WHERE account_login=?", (context.login,))
