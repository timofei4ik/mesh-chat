import json
import uuid
from datetime import datetime, timedelta, timezone


_SCHEDULE_REPEATS = {
    "none": None,
    "daily": timedelta(days=1),
    "weekly": timedelta(days=7),
    "monthly": timedelta(days=30),
}
_SCHEDULE_PACKET_TYPES = frozenset({"chat_message", "group_message"})


class ServerSchedulerMixin:
    def _parse_schedule_time(self, value):
        raw = str(value or "").strip()
        if not raw:
            return None
        normalized = raw.replace("Z", "+00:00")
        try:
            parsed = datetime.fromisoformat(normalized)
        except ValueError:
            return None
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)

    def create_scheduled_message(self, node_id, packet):
        login = (
            self.client_logins.get(node_id)
            or self.get_login_by_node(node_id)
            or ""
        ).strip().lower()
        if not login:
            return False, "unauthorized", None
        if not self.subscription_feature_enabled(login, "scheduled_messages"):
            return False, "meshpro_required", None

        status = self.subscription_status(login)
        limit = int(
            status.get("entitlements", {}).get("limits", {}).get(
                "scheduled_messages",
                0
            )
            or 0
        )
        active_count = self.db.execute(
            """
            SELECT COUNT(*)
            FROM scheduled_messages
            WHERE owner_login=? AND status='active'
            """,
            (login,)
        ).fetchone()[0]
        if limit <= 0 or active_count >= limit:
            return False, "schedule_limit_reached", None

        due_at = self._parse_schedule_time(packet.get("send_at"))
        now = datetime.now(timezone.utc)
        if due_at is None or due_at <= now + timedelta(seconds=2):
            return False, "invalid_schedule_time", None
        if due_at > now + timedelta(days=366):
            return False, "schedule_too_far", None

        repeat_interval = str(packet.get("repeat_interval") or "none").lower()
        if repeat_interval not in _SCHEDULE_REPEATS:
            return False, "invalid_repeat_interval", None
        if repeat_interval != "none" and not self.subscription_feature_enabled(
            login,
            "recurring_reminders"
        ):
            return False, "meshpro_required", None

        payloads = packet.get("payloads")
        if not isinstance(payloads, list) or not 1 <= len(payloads) <= 256:
            return False, "invalid_scheduled_payload", None
        sanitized = []
        for raw_payload in payloads:
            if not isinstance(raw_payload, dict):
                return False, "invalid_scheduled_payload", None
            payload = dict(raw_payload)
            if payload.get("type") not in _SCHEDULE_PACKET_TYPES:
                return False, "unsupported_scheduled_packet", None
            source_node = str(payload.get("source_node") or "")
            if not self._same_account_nodes(source_node, node_id):
                return False, "unauthorized", None
            if not str(payload.get("destination_node") or "").strip():
                return False, "invalid_scheduled_destination", None
            payload["source_node"] = node_id
            payload["sender"] = login
            payload.pop("created_at", None)
            sanitized.append(payload)

        is_channel = any(payload.get("is_channel") is True for payload in sanitized)
        if is_channel and not self.subscription_feature_enabled(
            login,
            "channel_scheduled_posts"
        ):
            return False, "meshpro_required", None

        schedule_id = str(uuid.uuid4())
        chat_key = str(packet.get("chat_key") or "").strip()[:240]
        preview_kind = "Channel post" if is_channel else "Scheduled message"
        preview_text = str(packet.get("preview") or preview_kind).strip()[:160]
        if not preview_text:
            preview_text = preview_kind
        self.db.execute(
            """
            INSERT INTO scheduled_messages(
                schedule_id,
                owner_login,
                source_node,
                payloads_json,
                preview_text,
                chat_key,
                repeat_interval,
                next_run_at,
                status
            )
            VALUES(?,?,?,?,?,?,?,?, 'active')
            """,
            (
                schedule_id,
                login,
                node_id,
                json.dumps(sanitized, ensure_ascii=False),
                preview_text,
                chat_key,
                repeat_interval,
                due_at.isoformat()
            )
        )
        self.db.commit()
        item = {
            "schedule_id": schedule_id,
            "chat_key": chat_key,
            "preview": preview_text,
            "repeat_interval": repeat_interval,
            "next_run_at": due_at.isoformat(),
            "run_count": 0,
        }
        return True, "ok", item

    def list_scheduled_messages(self, login):
        login = str(login or "").strip().lower()
        if not login:
            return []
        rows = self.db.execute(
            """
            SELECT schedule_id,
                   chat_key,
                   preview_text,
                   repeat_interval,
                   next_run_at,
                   run_count
            FROM scheduled_messages
            WHERE owner_login=? AND status='active'
            ORDER BY DATETIME(next_run_at), created_at
            """,
            (login,)
        ).fetchall()
        return [
            {
                "schedule_id": row[0],
                "chat_key": row[1] or "",
                "preview": row[2] or "Scheduled message",
                "repeat_interval": row[3] or "none",
                "next_run_at": row[4],
                "run_count": int(row[5] or 0),
            }
            for row in rows
        ]

    def cancel_scheduled_message(self, node_id, schedule_id):
        login = (
            self.client_logins.get(node_id)
            or self.get_login_by_node(node_id)
            or ""
        ).strip().lower()
        cursor = self.db.execute(
            """
            UPDATE scheduled_messages
            SET status='cancelled'
            WHERE schedule_id=? AND owner_login=? AND status='active'
            """,
            (str(schedule_id or ""), login)
        )
        self.db.commit()
        return cursor.rowcount > 0

    def _due_scheduled_rows(self):
        return self.db.execute(
            """
            SELECT schedule_id,
                   owner_login,
                   source_node,
                   payloads_json,
                   repeat_interval,
                   next_run_at,
                   chat_key
            FROM scheduled_messages
            WHERE status='active'
              AND DATETIME(next_run_at) <= DATETIME('now')
            ORDER BY DATETIME(next_run_at)
            LIMIT 50
            """
        ).fetchall()

    async def dispatch_due_scheduled_messages(self):
        dispatched = 0
        for row in self._due_scheduled_rows():
            schedule_id, login, source_node, payloads_json, repeat_interval, due_at, chat_key = row
            try:
                payloads = json.loads(payloads_json or "[]")
            except json.JSONDecodeError:
                payloads = []
            if not isinstance(payloads, list) or not payloads:
                self.db.execute(
                    "UPDATE scheduled_messages SET status='failed' WHERE schedule_id=?",
                    (schedule_id,)
                )
                self.db.commit()
                continue

            message_id = str(uuid.uuid4())
            created_at = datetime.now(timezone.utc).isoformat()
            sent_payload = None
            for raw_payload in payloads:
                if not isinstance(raw_payload, dict):
                    continue
                payload = dict(raw_payload)
                payload["packet_id"] = message_id
                payload["created_at"] = created_at
                payload["scheduled_message_id"] = schedule_id
                if payload.get("type") == "group_message":
                    payload["group_message_id"] = message_id
                saved = self.save_history_packet(payload)
                if saved is False:
                    continue
                await self.route_packet(payload)
                sent_payload = sent_payload or payload

            repeat_delta = _SCHEDULE_REPEATS.get(repeat_interval)
            if repeat_delta is None:
                self.db.execute(
                    """
                    UPDATE scheduled_messages
                    SET status='complete',
                        last_run_at=CURRENT_TIMESTAMP,
                        run_count=run_count+1
                    WHERE schedule_id=?
                    """,
                    (schedule_id,)
                )
            else:
                previous = self._parse_schedule_time(due_at) or datetime.now(timezone.utc)
                next_run = previous + repeat_delta
                now = datetime.now(timezone.utc)
                while next_run <= now:
                    next_run += repeat_delta
                self.db.execute(
                    """
                    UPDATE scheduled_messages
                    SET next_run_at=?,
                        last_run_at=CURRENT_TIMESTAMP,
                        run_count=run_count+1
                    WHERE schedule_id=?
                    """,
                    (next_run.isoformat(), schedule_id)
                )
            self.db.commit()
            dispatched += 1
            await self._notify_schedule_owner(
                login,
                {
                    "type": "scheduled_message_sent",
                    "schedule_id": schedule_id,
                    "message_id": message_id,
                    "chat_key": chat_key or "",
                    "repeat_interval": repeat_interval,
                    "sent_at": created_at,
                    "payload_type": (
                        sent_payload.get("type")
                        if isinstance(sent_payload, dict)
                        else ""
                    ),
                }
            )
        return dispatched

    async def _notify_schedule_owner(self, login, packet):
        for account_node in self.get_online_account_nodes(login):
            websocket = self.clients.get(account_node)
            if websocket is None:
                continue
            try:
                await websocket.send(json.dumps(packet, ensure_ascii=False))
            except Exception:
                continue
