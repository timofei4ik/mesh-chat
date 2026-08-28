import json
import uuid

try:
    from server.persistence.postgres import PostgresCompatibilityConnection
except ModuleNotFoundError:
    from persistence.postgres import PostgresCompatibilityConnection


class ServerPollsMixin:
    def initialize_poll_storage(self):
        self.db.execute(
            """
            CREATE TABLE IF NOT EXISTS server_polls(
                poll_id TEXT PRIMARY KEY,
                message_id TEXT NOT NULL UNIQUE,
                group_id TEXT NOT NULL,
                creator_login TEXT NOT NULL,
                question TEXT NOT NULL,
                options_json TEXT NOT NULL,
                is_quiz INTEGER NOT NULL DEFAULT 0,
                correct_option INTEGER,
                explanation TEXT NOT NULL DEFAULT '',
                allows_multiple INTEGER NOT NULL DEFAULT 0,
                is_anonymous INTEGER NOT NULL DEFAULT 1,
                is_closed INTEGER NOT NULL DEFAULT 0,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )
        self.db.execute(
            """
            CREATE TABLE IF NOT EXISTS server_poll_votes(
                poll_id TEXT NOT NULL,
                voter_login TEXT NOT NULL,
                option_index INTEGER NOT NULL,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(poll_id, voter_login, option_index),
                FOREIGN KEY(poll_id) REFERENCES server_polls(poll_id)
                    ON DELETE CASCADE
            )
            """
        )
        self.db.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_server_polls_group
            ON server_polls(group_id, created_at)
            """
        )
        self.db.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_server_poll_votes_poll
            ON server_poll_votes(poll_id, option_index)
            """
        )
        self._commit_storage()

    def _poll_actor(self, node_id):
        return str(
            self.client_logins.get(node_id)
            or self.get_login_by_node(node_id)
            or ""
        ).strip().lower()

    def _poll_group_access(self, login, group_id):
        if not login or not group_id:
            return False
        row = self.db.execute(
            """
            SELECT 1 FROM server_group_members
            WHERE group_id=? AND login=?
            LIMIT 1
            """,
            (group_id, login),
        ).fetchone()
        return row is not None

    def _poll_can_create(self, login, group_id):
        row = self.db.execute(
            """
            SELECT owner_node, admins_json, COALESCE(is_channel, 0)
            FROM server_groups WHERE group_id=?
            """,
            (group_id,),
        ).fetchone()
        if row is None or not self._poll_group_access(login, group_id):
            return False
        if not bool(row[2]):
            return True
        privileged_nodes = [row[0]]
        try:
            privileged_nodes.extend(json.loads(row[1] or "[]"))
        except (TypeError, ValueError):
            pass
        return any(self.get_login_by_node(node) == login for node in privileged_nodes)

    def _invalidate_poll_snapshots(
        self,
        group_id,
        poll_id,
        reason,
        operation_id,
    ):
        invalidate = getattr(self, "invalidate_sync_v2_snapshot", None)
        if not callable(invalidate):
            return
        rows = self.db.execute(
            """
            SELECT DISTINCT login FROM server_group_members
            WHERE group_id=? AND login IS NOT NULL AND login!=''
            """,
            (group_id,),
        ).fetchall()
        for row in rows:
            invalidate(
                str(row[0] or "").strip().lower(),
                reason,
                operation_id,
                {"poll_id": poll_id, "group_id": group_id},
            )

    def create_group_poll(self, node_id, packet):
        login = self._poll_actor(node_id)
        group_id = str(packet.get("group_id") or "").strip()
        message_id = str(packet.get("message_id") or "").strip()
        question = str(packet.get("question") or "").strip()
        raw_options = packet.get("options")
        options = []
        if isinstance(raw_options, list):
            for value in raw_options:
                option = str(value or "").strip()
                if option and option not in options:
                    options.append(option[:160])
        if not self._poll_can_create(login, group_id):
            return False, "group_access_denied", None
        if not message_id or not question or not 2 <= len(options) <= 10:
            return False, "invalid_poll", None
        message_row = self.db.execute(
            """
            SELECT group_id, sender_login FROM server_group_messages
            WHERE message_id=? LIMIT 1
            """,
            (message_id,),
        ).fetchone()
        if message_row is None:
            return False, "poll_message_not_found", None
        if (
            str(message_row[0] or "").strip() != group_id
            or str(message_row[1] or "").strip().lower() != login
        ):
            return False, "poll_message_mismatch", None
        is_quiz = packet.get("is_quiz") is True
        correct_option = packet.get("correct_option")
        try:
            correct_option = int(correct_option) if correct_option is not None else None
        except (TypeError, ValueError):
            correct_option = None
        if is_quiz and (correct_option is None or not 0 <= correct_option < len(options)):
            return False, "invalid_correct_option", None
        poll_id = str(packet.get("poll_id") or uuid.uuid4())
        try:
            self.db.execute(
                """
                INSERT INTO server_polls(
                    poll_id, message_id, group_id, creator_login, question,
                    options_json, is_quiz, correct_option, explanation,
                    allows_multiple, is_anonymous
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?)
                """,
                (
                    poll_id,
                    message_id,
                    group_id,
                    login,
                    question[:500],
                    json.dumps(options, ensure_ascii=False),
                    1 if is_quiz else 0,
                    correct_option,
                    str(packet.get("explanation") or "").strip()[:500],
                    1
                    if packet.get("allows_multiple") is True and not is_quiz
                    else 0,
                    1 if packet.get("is_anonymous") is not False else 0,
                ),
            )
            self._commit_storage()
        except Exception:
            existing = self.poll_for_message(message_id, login)
            if existing is not None and existing["creator_login"] == login:
                return True, "duplicate", existing
            raise
        self._invalidate_poll_snapshots(
            group_id,
            poll_id,
            "poll_created",
            f"poll-create:{poll_id}",
        )
        return True, "created", self.poll_by_id(poll_id, login)

    def vote_group_poll(self, node_id, poll_id, selected_options):
        login = self._poll_actor(node_id)
        with self.atomic_storage_transaction():
            lock_suffix = (
                " FOR UPDATE"
                if isinstance(self.db, PostgresCompatibilityConnection)
                else ""
            )
            row = self.db.execute(
                """
                SELECT group_id, options_json, allows_multiple, is_closed,
                       is_quiz
                FROM server_polls WHERE poll_id=?
                """
                + lock_suffix,
                (poll_id,),
            ).fetchone()
            if row is None:
                return False, "poll_not_found", None
            if not self._poll_group_access(login, row[0]):
                return False, "group_access_denied", None
            if bool(row[3]):
                return False, "poll_closed", None
            already_voted = self.db.execute(
                """
                SELECT 1 FROM server_poll_votes
                WHERE poll_id=? AND voter_login=? LIMIT 1
                """,
                (poll_id, login),
            ).fetchone()
            if already_voted is not None:
                return False, "already_voted", self.poll_by_id(poll_id, login)
            try:
                option_count = len(json.loads(row[1] or "[]"))
            except (TypeError, ValueError):
                option_count = 0
            choices = []
            if isinstance(selected_options, list):
                for value in selected_options:
                    try:
                        choice = int(value)
                    except (TypeError, ValueError):
                        continue
                    if 0 <= choice < option_count and choice not in choices:
                        choices.append(choice)
            allows_multiple = bool(row[2]) and not bool(row[4])
            if not choices or (not allows_multiple and len(choices) != 1):
                return False, "invalid_vote", None
            for choice in choices:
                self.db.execute(
                    """
                    INSERT INTO server_poll_votes(poll_id, voter_login, option_index)
                    VALUES(?,?,?)
                    """,
                    (poll_id, login, choice),
                )
            self.db.execute(
                "UPDATE server_polls SET updated_at=CURRENT_TIMESTAMP WHERE poll_id=?",
                (poll_id,),
            )
        self._invalidate_poll_snapshots(
            row[0],
            poll_id,
            "poll_voted",
            f"poll-vote:{poll_id}:{login}",
        )
        return True, "voted", self.poll_by_id(poll_id, login)

    def close_group_poll(self, node_id, poll_id):
        login = self._poll_actor(node_id)
        row = self.db.execute(
            "SELECT group_id, creator_login FROM server_polls WHERE poll_id=?",
            (poll_id,),
        ).fetchone()
        if row is None:
            return False, "poll_not_found", None
        if login != row[1] and not self._poll_can_create(login, row[0]):
            return False, "poll_close_denied", None
        self.db.execute(
            """
            UPDATE server_polls
            SET is_closed=1, updated_at=CURRENT_TIMESTAMP
            WHERE poll_id=?
            """,
            (poll_id,),
        )
        self._commit_storage()
        self._invalidate_poll_snapshots(
            row[0],
            poll_id,
            "poll_closed",
            f"poll-close:{poll_id}",
        )
        return True, "closed", self.poll_by_id(poll_id, login)

    def poll_for_message(self, message_id, viewer_login):
        row = self.db.execute(
            "SELECT poll_id FROM server_polls WHERE message_id=?",
            (message_id,),
        ).fetchone()
        return self.poll_by_id(row[0], viewer_login) if row else None

    def poll_by_id(self, poll_id, viewer_login):
        row = self.db.execute(
            """
            SELECT poll_id, message_id, group_id, creator_login, question,
                   options_json, is_quiz, correct_option, explanation,
                   allows_multiple, is_anonymous, is_closed, created_at
            FROM server_polls WHERE poll_id=?
            """,
            (poll_id,),
        ).fetchone()
        if row is None:
            return None
        options = json.loads(row[5] or "[]")
        counts = [0] * len(options)
        for option_index, count in self.db.execute(
            """
            SELECT option_index, COUNT(DISTINCT voter_login)
            FROM server_poll_votes WHERE poll_id=? GROUP BY option_index
            """,
            (poll_id,),
        ).fetchall():
            if 0 <= int(option_index) < len(counts):
                counts[int(option_index)] = int(count)
        selected = [
            int(item[0])
            for item in self.db.execute(
                """
                SELECT option_index FROM server_poll_votes
                WHERE poll_id=? AND voter_login=? ORDER BY option_index
                """,
                (poll_id, str(viewer_login or "").strip().lower()),
            ).fetchall()
        ]
        voter_count = self.db.execute(
            "SELECT COUNT(DISTINCT voter_login) FROM server_poll_votes WHERE poll_id=?",
            (poll_id,),
        ).fetchone()[0]
        normalized_viewer = str(viewer_login or "").strip().lower()
        can_view_correct = bool(row[6]) and (
            bool(selected)
            or bool(row[11])
            or normalized_viewer == str(row[3] or "").strip().lower()
        )
        return {
            "poll_id": row[0],
            "message_id": row[1],
            "group_id": row[2],
            "creator_login": row[3],
            "question": row[4],
            "options": options,
            "counts": counts,
            "selected_options": selected,
            "voter_count": int(voter_count or 0),
            "is_quiz": bool(row[6]),
            "correct_option": row[7] if can_view_correct else None,
            "explanation": row[8] or "",
            "allows_multiple": bool(row[9]),
            "is_anonymous": bool(row[10]),
            "is_closed": bool(row[11]),
            "created_at": row[12],
        }

    def polls_for_account(self, login):
        rows = self.db.execute(
            """
            SELECT poll_id FROM server_polls
            WHERE group_id IN (
                SELECT group_id FROM server_group_members WHERE login=?
            )
            ORDER BY created_at
            """,
            (str(login or "").strip().lower(),),
        ).fetchall()
        return [self.poll_by_id(row[0], login) for row in rows]

    async def broadcast_poll(self, poll):
        if not poll:
            return
        seen_logins = set()
        for node_id in self.get_group_delivery_nodes(poll["group_id"]):
            login = str(self.get_login_by_node(node_id) or "").strip().lower()
            if login in seen_logins:
                continue
            seen_logins.add(login)
            personalized = self.poll_by_id(poll["poll_id"], login)
            for account_node in await self._live_account_nodes(login):
                await self._send_live_packet(
                    account_node,
                    {"type": "poll_update", "poll": personalized},
                )
