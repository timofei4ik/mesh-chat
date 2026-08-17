import json


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
