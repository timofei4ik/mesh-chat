import json
from datetime import datetime, timedelta, timezone
from uuid import uuid4


RESTRICTED_PACKET_TYPES = frozenset(
    {
        "chat_message",
        "chat_request",
        "chat_response",
        "file_chunk",
        "file_manifest",
        "group_join_request",
        "group_join_response",
        "group_message",
        "group_message_edit",
        "group_pin",
        "group_reaction",
        "group_update",
        "message_edit",
        "message_pin",
        "message_reaction",
        "profile_update",
        "scheduled_message_create",
        "story_reaction",
        "story_update",
    }
)


class ModerationEnforcementError(RuntimeError):
    pass


class ServerModerationMixin:
    def moderation_account_access(self, login):
        with self.unit_of_work_factory() as unit_of_work:
            return unit_of_work.moderation.account_access(login)

    def moderation_packet_allowed(self, login, packet_type):
        access = self.moderation_account_access(login)
        if access["blocked"]:
            return False, "account_blocked"
        if access["restricted"] and packet_type in RESTRICTED_PACKET_TYPES:
            return False, "account_restricted"
        return True, "ok"

    async def apply_moderation_enforcement(
        self,
        report,
        action,
        admin_id,
        note="",
        duration_hours=24,
    ):
        action = str(action or "").strip().lower()
        if action == "hide":
            metadata = await self._moderation_hide_content(report)
            reversible = False
            expires_at = None
        elif action in {"warn", "restrict", "block"}:
            target_login = str(report.get("target_login") or "").strip().lower()
            if not target_login:
                raise ModerationEnforcementError("target_login_required")
            metadata = {"note": str(note or "")[:2000]}
            reversible = True
            expires_at = None
            if action == "restrict":
                try:
                    requested_hours = int(duration_hours or 24)
                except (TypeError, ValueError):
                    requested_hours = 24
                hours = max(1, min(requested_hours, 24 * 365))
                expires_at = (
                    datetime.now(timezone.utc) + timedelta(hours=hours)
                ).isoformat()
                metadata["duration_hours"] = hours
        else:
            raise ModerationEnforcementError("invalid_action")

        enforcement_id = str(uuid4())
        with self.unit_of_work_factory(write=True) as unit_of_work:
            unit_of_work.moderation.create_enforcement(
                {
                    "enforcement_id": enforcement_id,
                    "report_id": report["report_id"],
                    "action": action,
                    "subject_type": report["subject_type"],
                    "subject_id": report["subject_id"],
                    "target_login": str(
                        report.get("target_login") or ""
                    ).strip().lower(),
                    "expires_at": expires_at,
                    "reversible": reversible,
                    "metadata": metadata,
                    "created_by": admin_id,
                }
            )

        if action == "block":
            await self._disconnect_locally_blocked_account(
                str(report.get("target_login") or "").strip().lower()
            )
        return enforcement_id

    async def revoke_moderation_enforcement(
        self,
        enforcement_id,
        admin_id,
        note="",
    ):
        with self.unit_of_work_factory(write=True) as unit_of_work:
            enforcement = unit_of_work.moderation.enforcement_by_id(
                enforcement_id
            )
            if enforcement is None:
                raise ModerationEnforcementError("enforcement_not_found")
            if not enforcement["reversible"]:
                raise ModerationEnforcementError("enforcement_not_reversible")
            if enforcement["status"] != "active":
                raise ModerationEnforcementError("enforcement_not_active")
            changed = unit_of_work.moderation.revoke_enforcement(
                enforcement_id,
                admin_id,
                str(note or "")[:2000],
            )
        if not changed:
            raise ModerationEnforcementError("enforcement_not_active")
        return enforcement

    async def _moderation_hide_content(self, report):
        subject_type = str(report.get("subject_type") or "").strip().lower()
        subject_id = str(report.get("subject_id") or "").strip()
        if subject_type in {"message", "comment"}:
            group_row = self.db.execute(
                """
                SELECT group_id, sender_node
                FROM server_group_messages WHERE message_id=?
                """,
                (subject_id,),
            ).fetchone()
            if group_row:
                return await self._moderation_delete_group_message(
                    report, group_row[0], group_row[1]
                )
            file_row = self.db.execute(
                """
                SELECT group_id, sender_node, receiver_node
                FROM server_files WHERE file_id=?
                """,
                (subject_id,),
            ).fetchone()
            if file_row and file_row[0]:
                return await self._moderation_delete_group_message(
                    report, file_row[0], file_row[1]
                )
            direct_row = self.db.execute(
                """
                SELECT sender_node, receiver_node
                FROM direct_messages WHERE message_id=?
                """,
                (subject_id,),
            ).fetchone()
            if direct_row is None and file_row:
                direct_row = (file_row[1], file_row[2])
            if direct_row:
                return await self._moderation_delete_direct_message(
                    report, direct_row[0], direct_row[1]
                )
            raise ModerationEnforcementError("content_not_found")
        if subject_type == "story":
            return await self._moderation_delete_story(report)
        if subject_type in {"group", "channel"}:
            return await self._moderation_delete_group(report)
        raise ModerationEnforcementError("hide_not_supported_for_subject")

    async def _moderation_delete_direct_message(
        self,
        report,
        sender_node,
        receiver_node,
    ):
        packet = self._moderation_delete_packet(
            report,
            "message_delete",
            source_node=sender_node,
            destination_node=receiver_node,
            message_id=report["subject_id"],
        )
        await self._persist_and_fanout(packet, [receiver_node])
        return {"packet_type": "message_delete"}

    async def _moderation_delete_group_message(
        self,
        report,
        group_id,
        sender_node,
    ):
        targets = self.get_group_delivery_nodes(group_id)
        packet = self._moderation_delete_packet(
            report,
            "group_message_delete",
            source_node=sender_node,
            destination_node=targets[0] if targets else "",
            group_id=group_id,
            group_message_id=report["subject_id"],
        )
        await self._persist_and_fanout(packet, targets)
        return {
            "packet_type": "group_message_delete",
            "group_id": group_id,
        }

    async def _moderation_delete_story(self, report):
        row = self.db.execute(
            """
            SELECT owner_node, recipients_json, story_json
            FROM server_stories WHERE story_id=?
            """,
            (report["subject_id"],),
        ).fetchone()
        if not row:
            raise ModerationEnforcementError("content_not_found")
        targets = self._moderation_json_list(row[1])
        try:
            story = json.loads(row[2] or "{}")
        except (TypeError, ValueError):
            story = {}
        targets.extend(self._moderation_json_list(story.get("recipients")))
        packet = self._moderation_delete_packet(
            report,
            "story_delete",
            source_node=row[0],
            destination_node=targets[0] if targets else "",
            story_id=report["subject_id"],
        )
        await self._persist_and_fanout(packet, targets)
        return {"packet_type": "story_delete"}

    async def _moderation_delete_group(self, report):
        row = self.db.execute(
            """
            SELECT owner_node, COALESCE(is_channel, 0)
            FROM server_groups WHERE group_id=?
            """,
            (report["subject_id"],),
        ).fetchone()
        if not row:
            raise ModerationEnforcementError("content_not_found")
        targets = self.get_group_delivery_nodes(report["subject_id"])
        packet = self._moderation_delete_packet(
            report,
            "group_delete",
            source_node=row[0],
            destination_node=targets[0] if targets else "",
            group_id=report["subject_id"],
            is_channel=bool(row[1]),
        )
        await self._persist_and_fanout(packet, targets)
        return {
            "packet_type": "group_delete",
            "is_channel": bool(row[1]),
        }

    async def _persist_and_fanout(self, packet, targets):
        unique_targets = self._dedupe_account_nodes(targets)
        accounts = self.sync_v2_accounts_for_packet(packet, unique_targets)
        result = self.persist_history_mutation(packet, accounts)
        if result["saved"] is False:
            raise ModerationEnforcementError("content_delete_rejected")
        await self.mirror_packet_to_source_account_devices(packet)
        source_node = str(packet.get("source_node") or "")
        for target_node in unique_targets:
            if not target_node or self._same_account_nodes(
                source_node, target_node
            ):
                continue
            await self.route_packet(
                {
                    **packet,
                    "packet_id": str(uuid4()),
                    "destination_node": target_node,
                }
            )

    @staticmethod
    def _moderation_delete_packet(report, packet_type, **fields):
        return {
            "type": packet_type,
            "packet_id": str(uuid4()),
            "operation_id": f"moderation:{report['report_id']}:{packet_type}",
            "moderated": True,
            "moderation_report_id": report["report_id"],
            **fields,
        }

    async def _disconnect_locally_blocked_account(self, login):
        for node_id in self.get_account_node_ids(login):
            websocket = self.clients.get(node_id)
            if websocket is None:
                continue
            try:
                await self.send_server_error(
                    websocket,
                    "account_blocked",
                    "This account was blocked by moderation",
                )
                await websocket.close(code=1008, reason="account blocked")
            except Exception:
                pass

    @staticmethod
    def _moderation_json_list(value):
        if isinstance(value, list):
            return [str(item) for item in value if str(item or "").strip()]
        try:
            decoded = json.loads(value or "[]")
        except (TypeError, ValueError):
            return []
        return (
            [str(item) for item in decoded if str(item or "").strip()]
            if isinstance(decoded, list)
            else []
        )
