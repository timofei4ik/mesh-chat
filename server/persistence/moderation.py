import json
from datetime import datetime, timezone


class ModerationRepository:
    def __init__(self, connection):
        self._connection = connection

    def create_report(self, report):
        self._connection.execute(
            """
            INSERT INTO moderation_reports(
                report_id, reporter_login, reporter_node, subject_type,
                subject_id, conversation_id, target_login, reason,
                details, snapshot_json, status, priority
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            (
                report["report_id"], report["reporter_login"],
                report["reporter_node"], report["subject_type"],
                report["subject_id"], report["conversation_id"],
                report["target_login"], report["reason"],
                report["details"], json.dumps(
                    report.get("snapshot") or {}, ensure_ascii=False
                ), report.get("status", "new"),
                int(report.get("priority", 0)),
            ),
        )

    def list_reports(self, status="new", limit=100):
        status = str(status or "").strip().lower()
        where = "WHERE status=?" if status and status != "all" else ""
        parameters = [status] if where else []
        parameters.append(max(1, min(int(limit), 250)))
        rows = self._connection.execute(
            f"""
            SELECT report_id, reporter_login, reporter_node, subject_type,
                   subject_id, conversation_id, target_login, reason,
                   details, snapshot_json, status, priority, assigned_to,
                   ai_category, ai_confidence, ai_recommendation,
                   created_at, updated_at, resolved_at
            FROM moderation_reports
            {where}
            ORDER BY priority DESC, created_at ASC
            LIMIT ?
            """,
            parameters,
        ).fetchall()
        return [self._report_dict(row) for row in rows]

    def report_by_id(self, report_id):
        row = self._connection.execute(
            """
            SELECT report_id, reporter_login, reporter_node, subject_type,
                   subject_id, conversation_id, target_login, reason,
                   details, snapshot_json, status, priority, assigned_to,
                   ai_category, ai_confidence, ai_recommendation,
                   created_at, updated_at, resolved_at
            FROM moderation_reports WHERE report_id=?
            """,
            (str(report_id or ""),),
        ).fetchone()
        return self._report_dict(row) if row else None

    def record_decision(self, report_id, action_id, admin_id, action, note):
        resolved = action in {"keep", "hide", "warn", "restrict", "block"}
        status = "resolved" if resolved else action
        cursor = self._connection.execute(
            """
            UPDATE moderation_reports
            SET status=?, assigned_to=?, updated_at=CURRENT_TIMESTAMP,
                resolved_at=CASE WHEN ? THEN CURRENT_TIMESTAMP ELSE NULL END
            WHERE report_id=?
            """,
            (status, admin_id, resolved, report_id),
        )
        if not cursor.rowcount:
            return False
        self._connection.execute(
            """
            INSERT INTO moderation_actions(
                action_id, report_id, admin_id, action, note
            ) VALUES(?,?,?,?,?)
            """,
            (action_id, report_id, admin_id, action, note),
        )
        return True

    def actions_for_report(self, report_id):
        rows = self._connection.execute(
            """
            SELECT action_id, admin_id, action, note, created_at
            FROM moderation_actions
            WHERE report_id=? ORDER BY created_at ASC
            """,
            (report_id,),
        ).fetchall()
        return [
            {
                "action_id": row[0], "admin_id": row[1],
                "action": row[2], "note": row[3], "created_at": row[4],
            }
            for row in rows
        ]

    def append_action(self, report_id, action_id, admin_id, action, note):
        exists = self._connection.execute(
            "SELECT 1 FROM moderation_reports WHERE report_id=?",
            (report_id,),
        ).fetchone()
        if not exists:
            return False
        self._connection.execute(
            """
            INSERT INTO moderation_actions(
                action_id, report_id, admin_id, action, note
            ) VALUES(?,?,?,?,?)
            """,
            (action_id, report_id, admin_id, action, note),
        )
        return True

    def create_enforcement(self, enforcement):
        self._connection.execute(
            """
            INSERT INTO moderation_enforcements(
                enforcement_id, report_id, action, subject_type,
                subject_id, target_login, status, expires_at,
                reversible, metadata_json, created_by
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """,
            (
                enforcement["enforcement_id"], enforcement["report_id"],
                enforcement["action"], enforcement["subject_type"],
                enforcement["subject_id"], enforcement.get("target_login", ""),
                enforcement.get("status", "active"),
                enforcement.get("expires_at"),
                1 if enforcement.get("reversible", True) else 0,
                json.dumps(
                    enforcement.get("metadata") or {}, ensure_ascii=False
                ),
                enforcement["created_by"],
            ),
        )

    def enforcements_for_report(self, report_id):
        rows = self._connection.execute(
            """
            SELECT enforcement_id, report_id, action, subject_type,
                   subject_id, target_login, status, expires_at,
                   reversible, metadata_json, created_by, created_at,
                   revoked_at, revoked_by, revoke_note
            FROM moderation_enforcements
            WHERE report_id=? ORDER BY created_at ASC
            """,
            (report_id,),
        ).fetchall()
        return [self._enforcement_dict(row) for row in rows]

    def enforcement_by_id(self, enforcement_id):
        row = self._connection.execute(
            """
            SELECT enforcement_id, report_id, action, subject_type,
                   subject_id, target_login, status, expires_at,
                   reversible, metadata_json, created_by, created_at,
                   revoked_at, revoked_by, revoke_note
            FROM moderation_enforcements WHERE enforcement_id=?
            """,
            (enforcement_id,),
        ).fetchone()
        return self._enforcement_dict(row) if row else None

    def revoke_enforcement(self, enforcement_id, admin_id, note):
        cursor = self._connection.execute(
            """
            UPDATE moderation_enforcements
            SET status='revoked', revoked_at=CURRENT_TIMESTAMP,
                revoked_by=?, revoke_note=?
            WHERE enforcement_id=? AND status='active' AND reversible=1
            """,
            (admin_id, note, enforcement_id),
        )
        return bool(cursor.rowcount)

    def account_access(self, login):
        normalized = str(login or "").strip().lower()
        if not normalized:
            return {"blocked": False, "restricted": False}
        rows = self._connection.execute(
            """
            SELECT action, expires_at
            FROM moderation_enforcements
            WHERE target_login=? AND status='active'
              AND action IN ('restrict', 'block')
              AND (expires_at IS NULL OR expires_at>CURRENT_TIMESTAMP)
            ORDER BY CASE action WHEN 'block' THEN 0 ELSE 1 END,
                     created_at DESC
            """,
            (normalized,),
        ).fetchall()
        actions = {row[0] for row in rows}
        return {
            "blocked": "block" in actions,
            "restricted": "restrict" in actions,
        }

    @staticmethod
    def _report_dict(row):
        try:
            snapshot = json.loads(row[9] or "{}")
        except (TypeError, ValueError):
            snapshot = {}
        return {
            "report_id": row[0], "reporter_login": row[1],
            "reporter_node": row[2], "subject_type": row[3],
            "subject_id": row[4], "conversation_id": row[5],
            "target_login": row[6], "reason": row[7],
            "details": row[8], "snapshot": snapshot,
            "status": row[10], "priority": row[11],
            "assigned_to": row[12], "ai_category": row[13],
            "ai_confidence": row[14], "ai_recommendation": row[15],
            "created_at": row[16], "updated_at": row[17],
            "resolved_at": row[18],
        }

    @staticmethod
    def _enforcement_dict(row):
        try:
            metadata = json.loads(row[9] or "{}")
        except (TypeError, ValueError):
            metadata = {}
        status = row[6]
        if status == "active" and row[7]:
            try:
                expires_at = datetime.fromisoformat(
                    str(row[7]).replace("Z", "+00:00")
                )
                if expires_at.tzinfo is None:
                    expires_at = expires_at.replace(tzinfo=timezone.utc)
                if expires_at <= datetime.now(timezone.utc):
                    status = "expired"
            except ValueError:
                pass
        return {
            "enforcement_id": row[0], "report_id": row[1],
            "action": row[2], "subject_type": row[3],
            "subject_id": row[4], "target_login": row[5],
            "status": status, "expires_at": row[7],
            "reversible": bool(row[8]), "metadata": metadata,
            "created_by": row[10], "created_at": row[11],
            "revoked_at": row[12], "revoked_by": row[13],
            "revoke_note": row[14],
        }
