import asyncio
import hashlib
import json
from pathlib import Path
from uuid import uuid4

import websockets

try:
    from server.sync_v2_shadow import DELTA_SHADOW_EVENT_TYPES
except ModuleNotFoundError:
    from sync_v2_shadow import DELTA_SHADOW_EVENT_TYPES

SERVER_FILE_SYNC_CHUNK_SIZE = 256 * 1024
SERVER_STICKER_LIBRARY_INLINE_LIMIT = 512 * 1024
SERVER_STICKER_LIBRARY_SYNC_CHUNK_SIZE = 128 * 1024
SYNC_V2_EVENT_PAYLOAD_LIMIT = 64 * 1024
SYNC_V2_MAX_DELTA_EVENTS = 500


def sync_v2_delta_digest(events):
    canonical = json.dumps(
        events,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()
SYNC_V2_EVENT_PACKET_TYPES = frozenset(
    {
        "chat_message",
        "message_edit",
        "message_delete",
        "chat_delete",
        "message_pin",
        "message_reaction",
        "group_message",
        "group_update",
        "group_member_leave",
        "group_delete",
        "group_message_edit",
        "group_message_delete",
        "group_pin",
        "group_reaction",
        "profile_update",
        "story_update",
        "story_reaction",
        "story_view",
        "story_delete",
        "file_chunk",
        "sticker_library_update",
        "account_state_invalidate",
    }
)
SYNC_V2_TOMBSTONE_PACKET_TYPES = frozenset(
    {
        "message_delete",
        "chat_delete",
        "group_member_leave",
        "group_delete",
        "group_message_delete",
        "story_delete",
    }
)
SYNC_V2_BINARY_FIELDS = frozenset(
    {
        "data",
        "avatar_data",
        "group_avatar_data",
        "sticker_library",
    }
)
SYNC_V2_SNAPSHOT_ONLY_PACKET_TYPES = frozenset(
    {
        "profile_update",
        "story_view",
        "file_chunk",
        "sticker_library_update",
        "account_state_invalidate",
    }
)


class MutationRejectedError(RuntimeError):
    pass


class ServerSyncMixin:
    def persist_history_mutation(
        self,
        packet,
        account_logins,
        mutation_context=None,
    ):
        inserted = None
        try:
            with self.atomic_storage_transaction():
                saved = self.save_history_packet(packet)
                if saved is False:
                    raise MutationRejectedError()

                if saved not in {"duplicate", "pending"}:
                    self.record_sync_v2_event(packet, account_logins)

                if mutation_context:
                    inserted = self.mark_mutation_processed(
                        mutation_context["account_login"],
                        mutation_context["outbox_id"],
                        mutation_context["operation_id"],
                        packet.get("type"),
                        packet.get("packet_id")
                        or packet.get("group_message_id")
                        or packet.get("message_id")
                        or "",
                    )
        except MutationRejectedError:
            return {
                "saved": False,
                "processed_inserted": None,
            }

        return {
            "saved": saved,
            "processed_inserted": inserted,
        }

    def invalidate_sync_v2_snapshot(
        self,
        login,
        reason,
        operation_id,
        metadata=None,
    ):
        normalized_login = str(login or "").strip().lower()
        normalized_operation_id = str(operation_id or "").strip()
        if not normalized_login or not normalized_operation_id:
            return 0
        packet = {
            "type": "account_state_invalidate",
            "packet_id": normalized_operation_id,
            "operation_id": (
                f"account_state_invalidate:{normalized_operation_id}"
            ),
            "reason": str(reason or "account_state_changed").strip(),
            "sync_v2_requires_snapshot": True,
        }
        if isinstance(metadata, dict):
            packet["metadata"] = metadata
        return self.record_sync_v2_event(
            packet,
            [normalized_login],
        ).get(normalized_login, 0)

    def sync_v2_cursor(self, login):
        normalized_login = str(login or "").strip().lower()
        if not normalized_login:
            return 0
        row = self.db.execute(
            """
            SELECT MAX(
                COALESCE(
                    (
                        SELECT latest_cursor
                        FROM sync_event_state
                        WHERE account_login=?
                    ),
                    0
                ),
                COALESCE(
                    (
                        SELECT MAX(event_id)
                        FROM sync_events
                        WHERE account_login=?
                    ),
                    0
                )
            )
            """,
            (normalized_login, normalized_login)
        ).fetchone()
        return max(0, int(row[0] or 0)) if row else 0

    def sync_v2_retained_floor(self, login):
        normalized_login = str(login or "").strip().lower()
        if not normalized_login:
            return 0
        row = self.db.execute(
            """
            SELECT retained_floor
            FROM sync_event_state
            WHERE account_login=?
            """,
            (normalized_login,)
        ).fetchone()
        return max(0, int(row[0] or 0)) if row else 0

    def prune_sync_v2_events(self, login, through_cursor):
        normalized_login = str(login or "").strip().lower()
        try:
            requested_floor = max(0, int(through_cursor or 0))
        except (TypeError, ValueError):
            return self.sync_v2_retained_floor(normalized_login)
        if not normalized_login:
            return 0

        latest_cursor = self.sync_v2_cursor(normalized_login)
        retained_floor = min(requested_floor, latest_cursor)
        with self.atomic_storage_transaction():
            self.db.execute(
                """
                INSERT INTO sync_event_state(
                    account_login,
                    retained_floor,
                    latest_cursor,
                    updated_at
                )
                VALUES(?,?,?,CURRENT_TIMESTAMP)
                ON CONFLICT(account_login) DO UPDATE SET
                    retained_floor=MAX(
                        sync_event_state.retained_floor,
                        excluded.retained_floor
                    ),
                    latest_cursor=MAX(
                        sync_event_state.latest_cursor,
                        excluded.latest_cursor
                    ),
                    updated_at=CURRENT_TIMESTAMP
                """,
                (
                    normalized_login,
                    retained_floor,
                    latest_cursor,
                )
            )
            self.db.execute(
                """
                DELETE FROM sync_events
                WHERE account_login=?
                  AND event_id<=?
                """,
                (normalized_login, retained_floor)
            )
        return self.sync_v2_retained_floor(normalized_login)

    def sync_v2_accounts_for_packet(self, packet, extra_nodes=None):
        if not isinstance(packet, dict):
            return []
        if str(packet.get("type") or "").strip() not in SYNC_V2_EVENT_PACKET_TYPES:
            return []

        nodes = {
            str(node_id).strip()
            for node_id in (
                packet.get("source_node"),
                packet.get("destination_node"),
                packet.get("leaver_node"),
                packet.get("owner_node"),
                *(packet.get("members") or []),
                *(packet.get("admins") or []),
                *(extra_nodes or []),
            )
            if str(node_id or "").strip()
            and str(node_id).strip().upper() != "SERVER"
        }

        group_id = str(packet.get("group_id") or "").strip()
        if group_id:
            rows = self.db.execute(
                """
                SELECT node_id, login
                FROM server_group_members
                WHERE group_id=?
                """,
                (group_id,)
            ).fetchall()
            nodes.update(
                str(node_id).strip()
                for node_id, _ in rows
                if str(node_id or "").strip()
            )
        else:
            rows = []

        logins = {
            str(stored_login or "").strip().lower()
            for _, stored_login in rows
            if str(stored_login or "").strip()
        }
        for node_id in nodes:
            login = str(self.get_login_by_node(node_id) or "").strip().lower()
            if login:
                logins.add(login)

        source_login = str(
            self.get_login_by_node(packet.get("source_node")) or ""
        ).strip().lower()
        requested_login = str(packet.get("login") or "").strip().lower()
        if requested_login and requested_login == source_login:
            logins.add(requested_login)

        return sorted(logins)

    def _sync_v2_operation_id(self, packet):
        explicit_operation_id = str(
            packet.get("operation_id") or ""
        ).strip()
        if explicit_operation_id:
            return explicit_operation_id

        packet_type = str(packet.get("type") or "").strip()
        operation_id = str(
            packet.get("packet_id")
            or packet.get("group_message_id")
            or packet.get("message_id")
            or packet.get("story_id")
            or ""
        ).strip()
        if not operation_id:
            return ""
        return f"{packet_type}:{operation_id}"

    def _sync_v2_event_payload(self, packet):
        requires_snapshot = (
            str(packet.get("type") or "").strip()
            in SYNC_V2_SNAPSHOT_ONLY_PACKET_TYPES
            or any(
                packet.get(key) not in (None, "", [], {})
                for key in SYNC_V2_BINARY_FIELDS
            )
        )
        payload = {
            key: value
            for key, value in packet.items()
            if key not in SYNC_V2_BINARY_FIELDS
        }
        if requires_snapshot:
            payload["sync_v2_requires_snapshot"] = True
        encoded = json.dumps(
            payload,
            ensure_ascii=False,
            separators=(",", ":")
        )
        if len(encoded.encode("utf-8")) <= SYNC_V2_EVENT_PAYLOAD_LIMIT:
            return encoded

        compact = {
            key: payload.get(key)
            for key in (
                "type",
                "packet_id",
                "source_node",
                "destination_node",
                "message_id",
                "group_message_id",
                "group_id",
                "story_id",
                "chat_kind",
                "chat_id",
                "action",
            )
            if payload.get(key) is not None
        }
        compact["payload_omitted"] = True
        return json.dumps(
            compact,
            ensure_ascii=False,
            separators=(",", ":")
        )

    def normalize_group_packet_for_recipient(
        self,
        packet,
        recipient_login,
        recipient_node,
    ):
        """Localize this account's group identity to the receiving device."""
        if not isinstance(packet, dict) or not packet.get("group_id"):
            return packet

        normalized_login = str(recipient_login or "").strip().lower()
        normalized_node = str(recipient_node or "").strip()
        if not normalized_login or not normalized_node:
            return packet

        def localize(value):
            node_value = str(value or "").strip()
            if not node_value:
                return ""
            value_login = str(
                self.get_login_by_node(node_value) or ""
            ).strip().lower()
            if value_login == normalized_login:
                return normalized_node
            return node_value

        result = dict(packet)
        for key in ("owner_node", "leaver_node"):
            if key in result:
                result[key] = localize(result.get(key))
        for key in ("members", "admins"):
            values = result.get(key)
            if not isinstance(values, list):
                continue
            localized = []
            for value in values:
                node_value = localize(value)
                if node_value and node_value not in localized:
                    localized.append(node_value)
            result[key] = localized
        return result

    def account_group_ids(self, login, node_id):
        """Return the authoritative group membership set for an account."""
        normalized_login = str(login or "").strip().lower()
        normalized_node = str(node_id or "").strip()
        if not normalized_login and not normalized_node:
            return []
        rows = self.db.execute(
            """
            SELECT DISTINCT group_id
            FROM server_group_members
            WHERE login=? OR node_id=?
            ORDER BY group_id
            """,
            (normalized_login, normalized_node),
        ).fetchall()
        return [str(row[0]).strip() for row in rows if str(row[0]).strip()]

    def normalize_sync_v2_event_for_recipient(
        self,
        event,
        recipient_login,
        recipient_node,
    ):
        if not isinstance(event, dict):
            return event
        payload = event.get("payload")
        if not isinstance(payload, dict):
            return event
        normalized_payload = self.normalize_group_packet_for_recipient(
            payload,
            recipient_login,
            recipient_node,
        )
        if normalized_payload is payload:
            return event
        return {**event, "payload": normalized_payload}

    def record_sync_v2_event(self, packet, account_logins):
        packet_type = str(packet.get("type") or "").strip()
        if packet_type not in SYNC_V2_EVENT_PACKET_TYPES:
            return {}

        operation_id = self._sync_v2_operation_id(packet)
        if not operation_id:
            return {}

        payload_json = self._sync_v2_event_payload(packet)
        cursors = {}
        for login in sorted(
            {
                str(value or "").strip().lower()
                for value in account_logins or []
                if str(value or "").strip()
            }
        ):
            insert_cursor = self.db.execute(
                """
                INSERT OR IGNORE INTO sync_events(
                    account_login,
                    operation_id,
                    packet_type,
                    payload_json
                )
                VALUES(?,?,?,?)
                """,
                (
                    login,
                    operation_id,
                    packet_type,
                    payload_json,
                )
            )
            if insert_cursor.rowcount:
                event_id = max(0, int(insert_cursor.lastrowid or 0))
                self.db.execute(
                    """
                    INSERT INTO sync_event_state(
                        account_login,
                        retained_floor,
                        latest_cursor,
                        updated_at
                    )
                    VALUES(?,0,?,CURRENT_TIMESTAMP)
                    ON CONFLICT(account_login) DO UPDATE SET
                        latest_cursor=MAX(
                            sync_event_state.latest_cursor,
                            excluded.latest_cursor
                        ),
                        updated_at=CURRENT_TIMESTAMP
                    """,
                    (login, event_id)
                )
            cursors[login] = self.sync_v2_cursor(login)
        self._commit_storage()
        return cursors

    def list_sync_v2_events(
        self,
        login,
        after_cursor,
        limit=250,
        through_cursor=None,
    ):
        normalized_login = str(login or "").strip().lower()
        try:
            normalized_cursor = max(0, int(after_cursor or 0))
        except (TypeError, ValueError):
            normalized_cursor = 0
        try:
            normalized_limit = min(500, max(1, int(limit or 250)))
        except (TypeError, ValueError):
            normalized_limit = 250
        if through_cursor is None:
            normalized_through_cursor = self.sync_v2_cursor(normalized_login)
        else:
            try:
                normalized_through_cursor = max(0, int(through_cursor or 0))
            except (TypeError, ValueError):
                normalized_through_cursor = normalized_cursor
        rows = self.db.execute(
            """
            SELECT event_id,
                   operation_id,
                   packet_type,
                   payload_json,
                   created_at
            FROM sync_events
            WHERE account_login=?
              AND event_id>?
              AND event_id<=?
            ORDER BY event_id
            LIMIT ?
            """,
            (
                normalized_login,
                normalized_cursor,
                normalized_through_cursor,
                normalized_limit,
            )
        ).fetchall()
        events = []
        for event_id, operation_id, packet_type, payload_json, created_at in rows:
            malformed_payload = False
            try:
                payload = json.loads(payload_json)
            except (TypeError, ValueError, json.JSONDecodeError):
                payload = {}
                malformed_payload = True
            if not isinstance(payload, dict):
                payload = {}
                malformed_payload = True
            events.append(
                {
                    "event_id": event_id,
                    "cursor": event_id,
                    "operation_id": operation_id,
                    "packet_type": packet_type,
                    "tombstone": (
                        packet_type in SYNC_V2_TOMBSTONE_PACKET_TYPES
                    ),
                    "requires_snapshot": bool(
                        malformed_payload
                        or packet_type not in DELTA_SHADOW_EVENT_TYPES
                        or payload.get("type") != packet_type
                        or payload.get("sync_v2_requires_snapshot")
                        or payload.get("payload_omitted")
                    ),
                    "payload": payload,
                    "created_at": created_at,
                }
            )
        return events

    def plan_sync_v2_delivery(
        self,
        login,
        requested_cursor,
        supports_delta=False,
    ):
        normalized_login = str(login or "").strip().lower()
        try:
            source_cursor = max(0, int(requested_cursor or 0))
        except (TypeError, ValueError):
            source_cursor = 0
        target_cursor = self.sync_v2_cursor(normalized_login)
        retained_floor = self.sync_v2_retained_floor(normalized_login)

        snapshot_plan = {
            "mode": "snapshot",
            "source_cursor": source_cursor,
            "target_cursor": target_cursor,
            "retained_floor": retained_floor,
            "events": [],
        }
        if not supports_delta:
            return {**snapshot_plan, "reason": "delta_not_negotiated"}
        if source_cursor <= 0:
            return {**snapshot_plan, "reason": "initial_snapshot"}
        if source_cursor > target_cursor:
            return {**snapshot_plan, "reason": "future_cursor"}
        if source_cursor < retained_floor:
            return {**snapshot_plan, "reason": "pruned_cursor"}

        if source_cursor not in {retained_floor, target_cursor}:
            cursor_row = self.db.execute(
                """
                SELECT 1
                FROM sync_events
                WHERE account_login=? AND event_id=?
                LIMIT 1
                """,
                (normalized_login, source_cursor)
            ).fetchone()
            if not cursor_row:
                return {**snapshot_plan, "reason": "invalid_cursor"}

        event_count_row = self.db.execute(
            """
            SELECT COUNT(*)
            FROM sync_events
            WHERE account_login=?
              AND event_id>?
              AND event_id<=?
            """,
            (normalized_login, source_cursor, target_cursor)
        ).fetchone()
        event_count = max(0, int(event_count_row[0] or 0))
        if event_count > SYNC_V2_MAX_DELTA_EVENTS:
            return {**snapshot_plan, "reason": "delta_too_large"}

        events = self.list_sync_v2_events(
            normalized_login,
            source_cursor,
            limit=SYNC_V2_MAX_DELTA_EVENTS,
            through_cursor=target_cursor,
        )
        if len(events) != event_count:
            return {**snapshot_plan, "reason": "journal_range_changed"}
        if any(event.get("requires_snapshot") for event in events):
            return {**snapshot_plan, "reason": "unsafe_event"}

        return {
            "mode": "delta",
            "reason": "delta_safe",
            "source_cursor": source_cursor,
            "target_cursor": target_cursor,
            "retained_floor": retained_floor,
            "events": events,
        }

    def acknowledge_sync_v2_cursor(self, login, node_id, cursor):
        normalized_login = str(login or "").strip().lower()
        normalized_node = str(node_id or "").strip()
        try:
            normalized_cursor = max(0, int(cursor or 0))
        except (TypeError, ValueError):
            return False
        if not normalized_login or not normalized_node:
            return False

        current_cursor = self.sync_v2_cursor(normalized_login)
        if normalized_cursor > current_cursor:
            return False

        self.db.execute(
            """
            INSERT INTO sync_cursors(
                account_login,
                node_id,
                cursor,
                acknowledged_at
            )
            VALUES(?,?,?,CURRENT_TIMESTAMP)
            ON CONFLICT(account_login, node_id) DO UPDATE SET
                cursor=MAX(sync_cursors.cursor, excluded.cursor),
                acknowledged_at=CURRENT_TIMESTAMP
            """,
            (
                normalized_login,
                normalized_node,
                normalized_cursor,
            )
        )
        self._commit_storage()
        return True

    def _attach_story_engagement(self, cursor, stories, node_id):
        story_ids = [
            story.get("id")
            for story in stories
            if story.get("id")
        ]
        if not story_ids:
            return
        placeholders = ",".join("?" for _ in story_ids)
        cursor.execute(
            f"""
            SELECT story_id,
                   reactor_node,
                   reaction
            FROM server_story_reactions
            WHERE story_id IN ({placeholders})
              AND liked=1
            """,
            story_ids
        )
        reactions = {}
        for story_id, reactor_node, reaction in cursor.fetchall():
            if self._same_account_nodes(reactor_node, node_id):
                reactor_node = node_id
            bucket = reactions.setdefault(story_id, {})
            bucket.setdefault(reaction or "heart", []).append(reactor_node)
        for story in stories:
            story_reactions = {
                reaction: sorted(set(nodes))
                for reaction, nodes in reactions.get(
                    story.get("id"),
                    {}
                ).items()
            }
            story["reactions"] = story_reactions
            story["liked_by_node_ids"] = story_reactions.get("heart", [])

        cursor.execute(
            f"""
            SELECT story_id,
                   viewer_node
            FROM server_story_views
            WHERE story_id IN ({placeholders})
            """,
            story_ids
        )
        views = {}
        for story_id, viewer_node in cursor.fetchall():
            if self._same_account_nodes(viewer_node, node_id):
                viewer_node = node_id
            views.setdefault(story_id, []).append(viewer_node)
        for story in stories:
            story["viewed_by_node_ids"] = sorted(
                set(views.get(story.get("id"), []))
            )

    def build_sync_packet(
        self,
        login,
        node_id
    ):

        cursor = self.db.cursor()

        cursor.execute(
            """
            SELECT login,
                   node_id,
                   display_name,
                   public_username,
                   about,
                   avatar_data,
                   encryption_public_key,
                   COALESCE(profile_background, 'mesh'),
                   COALESCE(profile_effect, 'stars'),
                   COALESCE(profile_blink_shape, 'auto'),
                   COALESCE(avatar_decoration, 'none'),
                   COALESCE(profile_glow, 0),
                   COALESCE(profile_accent, 4282557941)
            FROM accounts
            WHERE login=?
               OR node_id=?
            ORDER BY CASE WHEN node_id=? THEN 0 ELSE 1 END
            LIMIT 1
            """,
            (
                login,
                node_id,
                node_id
            )
        )

        own_profile = None
        row = cursor.fetchone()

        if row:

            own_profile = {
                "login": row[0],
                "node_id": node_id,
                "canonical_node_id": row[1],
                "display_name": row[2],
                "public_username": row[3],
                "about": row[4],
                "avatar_data": row[5],
                "encryption_public_key": row[6],
                "node_aliases": self.get_account_node_ids(row[0]),
                **self._meshpro_public_profile_fields(
                    row[0],
                    row[7],
                    row[8],
                    row[9],
                    row[10],
                    row[11],
                    row[12]
                )
            }

        cursor.execute(
            """
            SELECT message_id,
                   sender_node,
                   sender_login,
                   sender_name,
                   receiver_node,
                   receiver_login,
                   message,
                   reply_to_message_id,
                   reply_to_text,
                   COALESCE(chat_kind, 'normal'),
                   COALESCE(chat_id, ''),
                   COALESCE(message_effect, 'none'),
                   created_at
            FROM direct_messages
            WHERE sender_login=?
               OR receiver_login=?
               OR sender_node=?
               OR receiver_node=?
            ORDER BY id
            """.replace(
                "ORDER BY id",
                "ORDER BY created_at"
            ),
            (
                login,
                login,
                node_id,
                node_id
            )
        )

        direct_messages = [
            {
                "message_id": row[0],
                "sender_node": row[1],
                "sender_login": row[2],
                "sender_name": row[3],
                "receiver_node": row[4],
                "receiver_login": row[5],
                "message": row[6],
                "reply_to_message_id": row[7],
                "reply_to_text": row[8],
                "chat_kind": row[9],
                "chat_id": row[10],
                "message_effect": row[11],
                "created_at": row[12]
            }
            for row in cursor.fetchall()
        ]

        cursor.execute(
            """
            SELECT DISTINCT g.group_id,
                            g.group_name,
                            g.members_json,
                            g.owner_node,
                            g.admins_json,
                            COALESCE(g.is_channel, 0),
                            COALESCE(g.group_about, ''),
                            COALESCE(g.group_avatar_data, ''),
                            COALESCE(g.comments_enabled, 1)
            FROM server_groups g
            JOIN server_group_members m
              ON m.group_id = g.group_id
            WHERE m.login=?
               OR m.node_id=?
            """,
            (
                login,
                node_id
            )
        )

        groups = [
            {
                "group_id": row[0],
                "group_name": row[1],
                "members": json.loads(
                    row[2] or "[]"
                ),
                "owner_node": row[3],
                "admins": json.loads(
                    row[4] or "[]"
                ),
                "is_channel": bool(row[5]),
                "group_about": row[6] or "",
                "group_avatar_data": row[7] or "",
                "comments_enabled": row[8] != 0
            }
            for row in cursor.fetchall()
        ]

        def sync_node_alias(value):
            value = (value or "").strip()
            if not value:
                return ""
            value_login = self.get_login_by_node(value)
            if value_login and value_login.strip().lower() == login:
                return node_id
            return value

        def sync_node_aliases(values):
            aliases = []
            for value in values:
                alias = sync_node_alias(value)
                if alias and alias not in aliases:
                    aliases.append(alias)
            return aliases

        for group in groups:
            group["owner_node"] = sync_node_alias(group["owner_node"])
            group["members"] = sync_node_aliases(group["members"])
            group["admins"] = sync_node_aliases(group["admins"])

        cursor.execute(
            """
            SELECT peer_node,
                   COALESCE(chat_kind, 'normal'),
                   COALESCE(chat_id, ''),
                   COALESCE(peer_login, ''),
                   deleted_at
            FROM server_chat_deletes
            WHERE owner_node=?
               OR owner_login=?
               OR owner_node IN (
                    SELECT node_id
                    FROM account_devices
                    WHERE login=?
               )
            """,
            (
                node_id,
                login,
                login,
            )
        )

        normalized_login = str(login or "").strip().lower()
        own_node_ids = set(self.get_account_node_ids(login))
        own_node_ids.add(node_id)

        def is_self_chat_delete(row):
            peer_node = str(row[0] or "").strip()
            peer_login = str(row[3] or "").strip().lower()
            if peer_node in own_node_ids or peer_login == normalized_login:
                return True
            resolved_login = str(
                self.get_login_by_node(peer_node) or ""
            ).strip().lower()
            return bool(resolved_login) and resolved_login == normalized_login

        deleted_threads = [
            {
                "peer_node": row[0],
                "chat_kind": row[1] or "normal",
                "chat_id": row[2] or "",
                "peer_login": row[3] or "",
                "deleted_at": row[4] or ""
            }
            for row in cursor.fetchall()
            if row[0] and not is_self_chat_delete(row)
        ]
        deleted_chat_ids = {
            item["chat_id"]
            for item in deleted_threads
            if item["chat_id"]
        }
        deleted_node_cutoffs = {}
        deleted_login_cutoffs = {}
        for item in deleted_threads:
            if item["chat_id"]:
                continue
            deleted_at = item["deleted_at"]
            peer_node = item["peer_node"]
            peer_login = str(item["peer_login"] or "").strip().lower()
            if peer_node and deleted_at > deleted_node_cutoffs.get(peer_node, ""):
                deleted_node_cutoffs[peer_node] = deleted_at
            if peer_login and deleted_at > deleted_login_cutoffs.get(peer_login, ""):
                deleted_login_cutoffs[peer_login] = deleted_at

        def visible_after_chat_delete(item):
            chat_id = item.get("chat_id") or ""
            if chat_id:
                return chat_id not in deleted_chat_ids

            sender_node = item.get("sender_node") or ""
            receiver_node = item.get("receiver_node") or ""
            sender_login = str(item.get("sender_login") or "").strip().lower()
            receiver_login = str(item.get("receiver_login") or "").strip().lower()
            sender_is_self = (
                sender_node in own_node_ids
                or sender_login == normalized_login
            )
            receiver_is_self = (
                receiver_node in own_node_ids
                or receiver_login == normalized_login
            )
            if sender_is_self:
                peer_node = receiver_node
                peer_login = receiver_login
            elif receiver_is_self:
                peer_node = sender_node
                peer_login = sender_login
            else:
                return True

            cutoff = max(
                deleted_node_cutoffs.get(peer_node, ""),
                deleted_login_cutoffs.get(peer_login, ""),
            )
            if not cutoff:
                return True
            return str(item.get("created_at") or "") > cutoff

        direct_messages = [
            message
            for message in direct_messages
            if visible_after_chat_delete(message)
        ]

        for group in groups:

            cursor.execute(
                """
                SELECT key_id,
                       key_envelope
                FROM server_group_keys
                WHERE group_id=?
                  AND (
                      member_login=?
                      OR member_node=?
                  )
                ORDER BY created_at,
                         key_id,
                         member_node
                """,
                (
                    group["group_id"],
                    login,
                    node_id
                )
            )

            group["group_keys"] = [
                {
                    "key_id": row[0],
                    "key_envelope": row[1]
                }
                for row in cursor.fetchall()
            ]

        group_ids = [
            group["group_id"]
            for group in groups
        ]

        group_messages = []

        if group_ids:

            placeholders = ",".join(
                "?"
                for _ in group_ids
            )

            cursor.execute(
                f"""
                SELECT message_id,
                       group_id,
                       group_name,
                       sender_node,
                       sender_login,
                       sender_name,
                       message,
                       reply_to_message_id,
                       reply_to_text,
                       members_json,
                       group_key_id,
                       COALESCE(message_effect, 'none'),
                       COALESCE(is_channel_comment, 0),
                       created_at
                FROM server_group_messages
                WHERE group_id IN ({placeholders})
                ORDER BY created_at
                """,
                group_ids
            )

            group_messages = [
                {
                    "message_id": row[0],
                    "group_id": row[1],
                    "group_name": row[2],
                    "sender_node": row[3],
                    "sender_login": row[4],
                    "sender_name": row[5],
                    "message": row[6],
                    "reply_to_message_id": row[7],
                    "reply_to_text": row[8],
                    "members": json.loads(
                        row[9] or "[]"
                    ),
                    "group_key_id": row[10],
                    "message_effect": row[11],
                    "is_channel_comment": bool(row[12]) or bool(row[7]),
                    "created_at": row[13]
                }
                for row in cursor.fetchall()
            ]

        message_ids = [
            message["message_id"]
            for message in direct_messages
        ] + [
            message["message_id"]
            for message in group_messages
        ]

        file_conditions = [
            "sender_login=?",
            "receiver_login=?",
            "sender_node=?",
            "receiver_node=?"
        ]

        file_params = [
            login,
            login,
            node_id,
            node_id
        ]

        if group_ids:

            placeholders = ",".join(
                "?"
                for _ in group_ids
            )

            file_conditions.append(
                f"group_id IN ({placeholders})"
            )

            file_params.extend(
                group_ids
            )

        file_where = f"({' OR '.join(file_conditions)})"

        cursor.execute(
            f"""
            SELECT file_id,
                   sender_node,
                   sender_login,
                   sender_name,
                   receiver_node,
                   receiver_login,
                   group_id,
                   COALESCE(group_name, ''),
                   COALESCE(is_channel, 0),
                   COALESCE(comments_enabled, 1),
                   filename,
                   caption,
                   COALESCE(reply_to_message_id, ''),
                   COALESCE(reply_to_text, ''),
                   COALESCE(is_channel_comment, 0),
                   data,
                   COALESCE(storage_path, ''),
                   COALESCE(sha256, ''),
                   COALESCE(size_bytes, 0),
                   group_key_id,
                   COALESCE(message_kind, 'file'),
                   COALESCE(chat_kind, 'normal'),
                   COALESCE(chat_id, ''),
                   COALESCE(message_effect, 'none'),
                   created_at
            FROM server_files
            WHERE {file_where}
            ORDER BY created_at
            """,
            file_params
        )

        files = [
            {
                "file_id": row[0],
                "sender_node": row[1],
                "sender_login": row[2],
                "sender_name": row[3],
                "receiver_node": row[4],
                "receiver_login": row[5],
                "group_id": row[6],
                "group_name": row[7] or "",
                "is_channel": bool(row[8]),
                "comments_enabled": row[9] != 0,
                "filename": row[10],
                "caption": row[11] or "",
                "reply_to_message_id": row[12] or "",
                "reply_to_text": row[13] or "",
                "is_channel_comment": bool(row[14]),
                "data": row[15],
                "_storage_path": row[16] or "",
                "file_sha256": row[17] or "",
                "file_size": int(row[18] or 0),
                "group_key_id": row[19],
                "message_kind": row[20] or "file",
                "chat_kind": row[21],
                "chat_id": row[22],
                "message_effect": row[23],
                "created_at": row[24]
            }
            for row in cursor.fetchall()
        ]

        cursor.execute(
            """
            SELECT message_id, text, language, duration_seconds
            FROM ai_voice_transcriptions
            WHERE login=?
            """,
            (str(login or "").strip().lower(),),
        )
        voice_transcriptions = {
            row[0]: {
                "transcription": row[1] or "",
                "transcription_language": row[2] or "",
                "transcription_duration_seconds": max(
                    0.0,
                    float(row[3] or 0),
                ),
            }
            for row in cursor.fetchall()
        }
        for file_info in files:
            transcription = voice_transcriptions.get(file_info["file_id"])
            if transcription:
                file_info.update(transcription)

        cursor.execute(
            """
            SELECT message_id, text, language
            FROM ai_image_ocr
            WHERE login=?
            """,
            (str(login or "").strip().lower(),),
        )
        image_ocr = {
            row[0]: {
                "ocr_text": row[1] or "",
                "ocr_language": row[2] or "",
                "ocr_processed": True,
            }
            for row in cursor.fetchall()
        }
        for file_info in files:
            ocr = image_ocr.get(file_info["file_id"])
            if ocr:
                file_info.update(ocr)

        files = [
            file_info
            for file_info in files
            if visible_after_chat_delete(file_info)
        ]

        message_ids += [
            file_info["file_id"]
            for file_info in files
            if file_info.get("file_id")
        ]

        cursor.execute(
            """
            SELECT story_id,
                   owner_node,
                   owner_login,
                   story_json,
                   recipients_json
            FROM server_stories
            WHERE DATETIME(created_at) >= DATETIME('now', '-1 day')
            ORDER BY created_at DESC
            """
        )

        stories = []
        story_ids = []

        for (
            story_id,
            owner_node,
            owner_login,
            story_json,
            recipients_json
        ) in cursor.fetchall():
            try:
                recipients = set(json.loads(recipients_json or "[]"))
                story = json.loads(story_json or "{}")
            except json.JSONDecodeError:
                continue

            owner_login = (
                owner_login
                or self.get_login_by_node(owner_node)
                or ""
            ).strip().lower()
            recipient_logins = {
                (self.get_login_by_node(recipient) or "").strip().lower()
                for recipient in recipients
            }

            if (
                node_id != owner_node
                and node_id not in recipients
                and login != owner_login
                and login not in recipient_logins
            ):
                continue

            if not isinstance(story, dict):
                continue

            story["id"] = story.get("id") or story_id
            story["owner_node"] = (
                node_id
                if owner_login and owner_login == login
                else story.get("owner_node") or owner_node
            )
            stories.append(story)
            story_ids.append(story_id)

        self._attach_story_engagement(cursor, stories, node_id)

        story_archive = []
        subscription = self.subscription_status(login)
        entitlements = subscription.get("entitlements", {})
        archive_enabled = bool(
            subscription.get("active")
            and entitlements.get("features", {}).get("story_server_archive")
        )
        archive_days = int(
            entitlements.get("limits", {}).get(
                "server_story_archive_days",
                0
            )
            or 0
        )
        if archive_enabled and archive_days > 0:
            cursor.execute(
                """
                SELECT story_id,
                       owner_node,
                       story_json
                FROM server_stories
                WHERE owner_login=?
                  AND DATETIME(created_at) >= DATETIME('now', ?)
                ORDER BY created_at DESC
                """,
                (login, f"-{archive_days} days")
            )
            for story_id, owner_node, story_json in cursor.fetchall():
                try:
                    story = json.loads(story_json or "{}")
                except json.JSONDecodeError:
                    continue
                if not isinstance(story, dict):
                    continue
                story["id"] = story.get("id") or story_id
                story["owner_node"] = node_id
                story_archive.append(story)
            self._attach_story_engagement(cursor, story_archive, node_id)

        reactions = []
        pins = []

        if message_ids:

            placeholders = ",".join(
                "?"
                for _ in message_ids
            )

            cursor.execute(
                f"""
                SELECT scope,
                       message_id,
                       reactor_node,
                       reactor_login,
                       reactor_identity,
                       reaction
                FROM server_reactions
                WHERE message_id IN ({placeholders})
                """,
                message_ids
            )

            reactions = [
                {
                    "scope": row[0],
                    "message_id": row[1],
                    "reactor_node": row[2],
                    "reactor_login": row[3],
                    "reactor_identity": row[4],
                    "reaction": row[5]
                }
                for row in cursor.fetchall()
            ]

            cursor.execute(
                f"""
                SELECT scope,
                       message_id,
                       pinner_node,
                       text,
                       group_key_id,
                       created_at
                FROM server_pins
                WHERE message_id IN ({placeholders})
                ORDER BY created_at
                """,
                message_ids
            )

            pins = [
                {
                    "scope": row[0],
                    "message_id": row[1],
                    "pinner_node": row[2],
                    "text": row[3],
                    "group_key_id": row[4],
                    "created_at": row[5]
                }
                for row in cursor.fetchall()
            ]

        profile_nodes = {
            node_id
        }

        for message in direct_messages:
            profile_nodes.add(message.get("sender_node"))
            profile_nodes.add(message.get("receiver_node"))

        for message in group_messages:
            profile_nodes.add(message.get("sender_node"))

        for file_info in files:
            profile_nodes.add(file_info.get("sender_node"))
            profile_nodes.add(file_info.get("receiver_node"))

        for story in stories:
            profile_nodes.add(story.get("owner_node"))
            for reactor_node in story.get("liked_by_node_ids") or []:
                profile_nodes.add(reactor_node)
            for viewer_node in story.get("viewed_by_node_ids") or []:
                profile_nodes.add(viewer_node)

        profile_nodes = [
            profile_node
            for profile_node in profile_nodes
            if profile_node
        ]

        profiles = []

        if profile_nodes:

            placeholders = ",".join(
                "?"
                for _ in profile_nodes
            )

            cursor.execute(
                f"""
                SELECT a.login,
                       ids.node_id,
                       a.display_name,
                       a.public_username,
                       a.about,
                       a.avatar_data,
                       a.encryption_public_key,
                       COALESCE(a.profile_background, 'mesh'),
                       COALESCE(a.profile_effect, 'stars'),
                       COALESCE(a.profile_blink_shape, 'auto'),
                       COALESCE(a.avatar_decoration, 'none'),
                       COALESCE(a.profile_glow, 0),
                       COALESCE(a.profile_accent, 4282557941)
                FROM (
                    SELECT ? AS node_id
                    {''.join([' UNION SELECT ?' for _ in profile_nodes[1:]])}
                ) ids
                JOIN account_devices d
                  ON d.node_id=ids.node_id
                JOIN accounts a
                  ON a.login=d.login
                UNION
                SELECT a.login,
                       a.node_id,
                       a.display_name,
                       a.public_username,
                       a.about,
                       a.avatar_data,
                       a.encryption_public_key,
                       COALESCE(a.profile_background, 'mesh'),
                       COALESCE(a.profile_effect, 'stars'),
                       COALESCE(a.profile_blink_shape, 'auto'),
                       COALESCE(a.avatar_decoration, 'none'),
                       COALESCE(a.profile_glow, 0),
                       COALESCE(a.profile_accent, 4282557941)
                FROM accounts a
                WHERE a.node_id IN ({placeholders})
                """,
                profile_nodes + profile_nodes
            )

            profiles = [
                {
                    "login": row[0],
                    "node_id": row[1],
                    "display_name": row[2],
                    "public_username": row[3],
                    "about": row[4],
                    "avatar_data": row[5],
                    "encryption_public_key": row[6],
                    "node_aliases": self.get_account_node_ids(row[0]),
                    **self._meshpro_public_profile_fields(
                        row[0],
                        row[7],
                        row[8],
                        row[9],
                        row[10],
                        row[11],
                        row[12]
                    )
                }
                for row in cursor.fetchall()
            ]

        cursor.execute(
            """
            SELECT library_json
            FROM server_sticker_libraries
            WHERE login=?
            LIMIT 1
            """,
            (
                login,
            )
        )
        sticker_library = None
        row = cursor.fetchone()
        if row:
            try:
                decoded = json.loads(row[0] or "{}")
                if isinstance(decoded, dict):
                    sticker_library = decoded
            except json.JSONDecodeError:
                sticker_library = None

        schedule_lister = getattr(self, "list_scheduled_messages", None)
        scheduled_messages = (
            schedule_lister(login)
            if callable(schedule_lister)
            else []
        )

        return {
            "type": "server_sync",
            "profile": own_profile,
            "profiles": profiles,
            "direct_messages": direct_messages,
            "groups": groups,
            "group_messages": group_messages,
            "files": files,
            "stories": stories,
            "story_archive": story_archive,
            "chat_preferences": self.get_chat_preferences(login),
            "meshpro_preferences": self.get_meshpro_preferences(login),
            "scheduled_messages": scheduled_messages,
            "sticker_library": sticker_library,
            "reactions": reactions,
            "pins": pins
        }

    async def send_account_sync(
        self,
        websocket,
        login,
        node_id,
        supports_sticker_library_chunks=False,
        supports_sync_v2=False,
        supports_sync_v2_delta=False,
        requested_sync_cursor=0,
    ):
        sync_plan = self.plan_sync_v2_delivery(
            login,
            requested_sync_cursor,
            supports_delta=(
                supports_sync_v2
                and supports_sync_v2_delta
            ),
        )
        snapshot_cursor = (
            sync_plan["target_cursor"] if supports_sync_v2 else 0
        )

        if supports_sync_v2 and sync_plan["mode"] == "delta":
            sync_id = str(uuid4())
            events = [
                self.normalize_sync_v2_event_for_recipient(
                    event,
                    login,
                    node_id,
                )
                for event in sync_plan["events"]
            ]
            event_digest = sync_v2_delta_digest(events)
            await websocket.send(
                json.dumps(
                    {
                        "type": "server_sync_delta_begin",
                        "version": 2,
                        "sync_id": sync_id,
                        "source_cursor": sync_plan["source_cursor"],
                        "target_cursor": sync_plan["target_cursor"],
                        "retained_floor": sync_plan["retained_floor"],
                        "event_count": len(events),
                        "event_digest_sha256": event_digest,
                    },
                    ensure_ascii=False,
                )
            )
            for event in events:
                await websocket.send(
                    json.dumps(
                        {
                            "type": "server_sync_delta_event",
                            "sync_id": sync_id,
                            "event": event,
                        },
                        ensure_ascii=False,
                    )
                )
                await asyncio.sleep(0)
            await websocket.send(
                json.dumps(
                    {
                        "type": "server_sync_done",
                        "total_files": 0,
                        "sync_cursor": sync_plan["target_cursor"],
                        "sync_v2": {
                            "version": 2,
                            "mode": "delta",
                            "sync_id": sync_id,
                            "source_cursor": sync_plan["source_cursor"],
                            "cursor": sync_plan["target_cursor"],
                            "retained_floor": sync_plan["retained_floor"],
                            "event_count": len(events),
                            "event_digest_sha256": event_digest,
                        },
                    },
                    ensure_ascii=False,
                )
            )
            return

        packet = self.build_sync_packet(
            login,
            node_id
        )

        if supports_sync_v2:
            packet["sync_v2"] = {
                "version": 2,
                "mode": "snapshot",
                "cursor": snapshot_cursor,
                "source_cursor": sync_plan["source_cursor"],
                "retained_floor": sync_plan["retained_floor"],
                "reason": sync_plan["reason"],
            }

        file_payloads = []
        sticker_library_payload = ""

        for file_info in packet.get(
            "files",
            []
        ):

            data = file_info.pop(
                "data",
                ""
            ) or ""
            storage_path = file_info.pop("_storage_path", "") or ""

            if data or (storage_path and Path(storage_path).is_file()):
                file_payloads.append(
                    (
                        dict(file_info),
                        data,
                        storage_path,
                    )
                )

        sticker_library = packet.get("sticker_library")
        if isinstance(sticker_library, dict):
            encoded_library = json.dumps(
                sticker_library,
                ensure_ascii=False,
                separators=(",", ":")
            )
            if (
                len(encoded_library.encode("utf-8"))
                > SERVER_STICKER_LIBRARY_INLINE_LIMIT
            ):
                packet["sticker_library"] = None
                if supports_sticker_library_chunks:
                    sticker_library_payload = encoded_library
                    packet["sticker_library_chunked"] = True
                else:
                    packet["sticker_library_omitted"] = True

        await websocket.send(
            json.dumps(
                packet,
                ensure_ascii=False
            )
        )

        if sticker_library_payload:
            total_sticker_chunks = max(
                1,
                (
                    len(sticker_library_payload)
                    + SERVER_STICKER_LIBRARY_SYNC_CHUNK_SIZE
                    - 1
                )
                // SERVER_STICKER_LIBRARY_SYNC_CHUNK_SIZE
            )
            for chunk_index in range(total_sticker_chunks):
                start = (
                    chunk_index
                    * SERVER_STICKER_LIBRARY_SYNC_CHUNK_SIZE
                )
                await websocket.send(
                    json.dumps(
                        {
                            "type": "server_sticker_library_sync_chunk",
                            "chunk_index": chunk_index,
                            "total_chunks": total_sticker_chunks,
                            "data": sticker_library_payload[
                                start:
                                start + SERVER_STICKER_LIBRARY_SYNC_CHUNK_SIZE
                            ]
                        },
                        ensure_ascii=False
                    )
                )
                await asyncio.sleep(0)

        total_files = len(
            file_payloads
        )

        for file_number, (
            file_info,
            data,
            storage_path,
        ) in enumerate(
            file_payloads,
            start=1
        ):
            if storage_path and Path(storage_path).is_file():
                raw_chunk_size = max(1, SERVER_FILE_SYNC_CHUNK_SIZE // 2)
                payload_size = Path(storage_path).stat().st_size
                total_chunks = max(
                    1,
                    (payload_size + raw_chunk_size - 1) // raw_chunk_size,
                )
                with Path(storage_path).open("rb") as source:
                    for chunk_index in range(total_chunks):
                        chunk_data = source.read(raw_chunk_size)
                        if not chunk_data:
                            break
                        await websocket.send(
                            json.dumps(
                                {
                                    "type": "server_file_sync_chunk",
                                    **file_info,
                                    "chunk_index": chunk_index,
                                    "total_chunks": total_chunks,
                                    "file_number": file_number,
                                    "total_files": total_files,
                                    "data": chunk_data.hex(),
                                },
                                ensure_ascii=False,
                            )
                        )
                        await asyncio.sleep(0)
                continue

            total_chunks = max(
                1,
                (
                    len(data)
                    + SERVER_FILE_SYNC_CHUNK_SIZE
                    - 1
                )
                // SERVER_FILE_SYNC_CHUNK_SIZE
            )

            for chunk_index in range(total_chunks):
                start = chunk_index * SERVER_FILE_SYNC_CHUNK_SIZE
                await websocket.send(
                    json.dumps(
                        {
                            "type": "server_file_sync_chunk",
                            **file_info,
                            "chunk_index": chunk_index,
                            "total_chunks": total_chunks,
                            "file_number": file_number,
                            "total_files": total_files,
                            "data": data[
                                start:start + SERVER_FILE_SYNC_CHUNK_SIZE
                            ],
                        },
                        ensure_ascii=False,
                    )
                )
                await asyncio.sleep(0)

        await websocket.send(
            json.dumps(
                {
                    "type": "server_sync_done",
                    "total_files": total_files,
                    **(
                        {
                            "sync_v2": {
                                "version": 2,
                                "mode": "snapshot",
                                "cursor": snapshot_cursor,
                                "source_cursor": sync_plan["source_cursor"],
                                "retained_floor": sync_plan["retained_floor"],
                                "reason": sync_plan["reason"],
                            },
                            "sync_cursor": snapshot_cursor,
                        }
                        if supports_sync_v2
                        else {}
                    )
                },
                ensure_ascii=False
            )
        )

    async def send_user_list(self):

        users = []

        try:
            client_names = list(self.client_names.items())
        except RuntimeError:
            client_names = []

        for node_id, username in client_names:

            profile = self.get_profile_by_node(node_id)

            users.append(
                {
                    "node_id": node_id,
                    "login": profile.get("login"),
                    "username": username,
                    "display_name": profile.get("display_name") or username,
                    "public_username": profile.get("public_username"),
                    "about": profile.get("about"),
                    "avatar_data": profile.get("avatar_data"),
                    "encryption_public_key": profile.get("encryption_public_key"),
                    "meshpro_badge": profile.get("meshpro_badge", False),
                    "profile_background": profile.get(
                        "profile_background",
                        "mesh"
                    ),
                    "profile_effect": profile.get(
                        "profile_effect",
                        "nodes"
                    ),
                    "profile_blink_shape": profile.get(
                        "profile_blink_shape",
                        "auto"
                    ),
                    "avatar_decoration": profile.get(
                        "avatar_decoration",
                        "none"
                    ),
                    "profile_glow": profile.get("profile_glow", False),
                    "profile_accent": profile.get(
                        "profile_accent",
                        4282557941
                    )
                }
            )

        packet = {
            "type": "server_users",
            "users": users
        }

        dead = []

        try:
            client_items = list(self.clients.items())
        except RuntimeError:
            client_items = []

        for node_id, websocket in client_items:

            try:

                await websocket.send(
                    json.dumps(
                        packet,
                        ensure_ascii=False
                    )
                )

            except websockets.ConnectionClosed:

                dead.append(
                    node_id
                )

        for node_id in dead:

            self.clients.pop(
                node_id,
                None
            )

            self.client_names.pop(
                node_id,
                None
            )
