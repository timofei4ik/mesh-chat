"""SQL-backed, account-bound live delivery with at-least-once retries."""

import hashlib
import json
import time
from server.account_deletion import AccountDataPolicy


RELIABLE_PACKET_TYPES = frozenset({
    "chat_message", "group_message",
})


class DeliveryOutbox:
    def __init__(self, connection):
        self.db = connection
        if hasattr(connection, "raw_connection"):
            with connection.transaction():
                self.db.execute("SELECT pg_advisory_xact_lock(?)", (0x4D455349,))
                self._initialize_schema()
        else:
            self._initialize_schema()

    def _initialize_schema(self):
        self.db.execute("""
            CREATE TABLE IF NOT EXISTS realtime_delivery_outbox(
                delivery_id TEXT PRIMARY KEY,
                destination_node TEXT NOT NULL,
                account_login TEXT NOT NULL,
                packet_json TEXT NOT NULL,
                required_capability TEXT NOT NULL,
                created_at DOUBLE PRECISION NOT NULL,
                next_attempt_at DOUBLE PRECISION NOT NULL DEFAULT 0,
                attempts INTEGER NOT NULL DEFAULT 0
            )
        """)
        self.db.execute("""
            CREATE INDEX IF NOT EXISTS idx_delivery_node_due
            ON realtime_delivery_outbox(destination_node, account_login, next_attempt_at)
        """)
        self.db.execute("""
            CREATE INDEX IF NOT EXISTS idx_delivery_created
            ON realtime_delivery_outbox(created_at)
        """)
        self.db.commit()

    def enqueue(self, node_id, login, packet, required_capability=""):
        required_capability = required_capability or ""
        payload = {key: value for key, value in packet.items()
                   if key != "_delivery_id"}
        encoded = json.dumps(payload, sort_keys=True, ensure_ascii=False,
                             separators=(",", ":"))
        identity = json.dumps([node_id, login, required_capability, encoded])
        delivery_id = hashlib.sha256(identity.encode()).hexdigest()
        self.db.execute("""
            INSERT OR IGNORE INTO realtime_delivery_outbox(
                delivery_id, destination_node, account_login, packet_json,
                required_capability, created_at
            ) VALUES(?,?,?,?,?,?)
        """, (delivery_id, node_id, login, encoded,
              required_capability or "", time.time()))
        self.db.commit()
        return delivery_id

    def pending(self, node_id, login, limit=32):
        return self.db.execute("""
            SELECT delivery_id, packet_json, required_capability, attempts
            FROM realtime_delivery_outbox
            WHERE destination_node=? AND account_login=? AND next_attempt_at<=?
            ORDER BY created_at, delivery_id LIMIT ?
        """, (node_id, login, time.time(), min(128, max(1, limit)))).fetchall()

    def claim(self, delivery_id):
        now = time.time()
        row = self.db.execute("""
            SELECT attempts FROM realtime_delivery_outbox WHERE delivery_id=?
        """, (delivery_id,)).fetchone()
        if row is None:
            return False
        delay = min(30, 2 ** min(5, int(row[0]) + 1))
        changed = self.db.execute("""
            UPDATE realtime_delivery_outbox
            SET next_attempt_at=?, attempts=attempts+1
            WHERE delivery_id=? AND next_attempt_at<=?
        """, (now + delay, delivery_id, now)).rowcount
        self.db.commit()
        return changed > 0

    def acknowledge(self, node_id, login, delivery_id):
        # The authenticated account and node must both match. Knowing an ID
        # from another device is not authorization to remove its queued packet.
        row = self.db.execute("""
            DELETE FROM realtime_delivery_outbox
            WHERE delivery_id=? AND destination_node=? AND account_login=?
            RETURNING created_at
        """, (delivery_id, node_id, login)).fetchone()
        self.db.commit()
        return None if row is None else max(0.0, time.time() - float(row[0]))

    def stats(self):
        row = self.db.execute("""
            SELECT COUNT(*), MIN(created_at), COALESCE(SUM(attempts), 0)
            FROM realtime_delivery_outbox
        """).fetchone()
        return {
            "delivery_queue_depth": int(row[0]),
            "delivery_oldest_seconds": max(0.0, time.time() - float(row[1])) if row[1] else 0,
        }

    def delete_account(self, login):
        self.db.execute("DELETE FROM realtime_delivery_outbox WHERE account_login=?", (login,))
        self.db.commit()


class DeliveryDeletionOwner:
    name = "reliable_delivery"
    policies = (AccountDataPolicy(name, "realtime_delivery_outbox"),)

    def __init__(self, connection):
        self.db = connection

    def delete_account(self, context):
        # Leave the surrounding account-deletion transaction in control.
        self.db.execute("DELETE FROM realtime_delivery_outbox WHERE account_login=?",
                        (context.login,))
        # Also remove retained packets authored by the deleted account.
        for delivery_id, encoded in self.db.execute(
                "SELECT delivery_id, packet_json FROM realtime_delivery_outbox").fetchall():
            packet = json.loads(encoded)
            if (packet.get("sender_login") == context.login
                    or packet.get("source_node") in context.nodes):
                self.db.execute("DELETE FROM realtime_delivery_outbox WHERE delivery_id=?",
                                (delivery_id,))
