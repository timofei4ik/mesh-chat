import hashlib
import json
import re
import secrets
import shutil
from pathlib import Path

try:
    from server.config import PASSWORD_ITERATIONS
except ModuleNotFoundError:
    from config import PASSWORD_ITERATIONS


class ServerAuthMixin:
    def hash_password(
        self,
        password,
        salt_hex
    ):

        return hashlib.pbkdf2_hmac(
            "sha256",
            password.encode(
                "utf-8"
            ),
            bytes.fromhex(
                salt_hex
            ),
            PASSWORD_ITERATIONS
        ).hex()

    def authenticate_account(
        self,
        login,
        password,
        node_id,
        display_name,
        verify_only=False,
        public_username=None,
        about=None,
        avatar_data=None,
        encryption_public_key=None,
        allow_registration=True,
        reactivate_device=False,
        email=None,
        email_verified=False,
    ):

        login = (
            login
            or ""
        ).strip().lower()

        password = password or ""
        public_username = self.normalize_public_username(
            public_username
            or login
        )

        if not login or not password:
            return False, "missing login or password"

        cursor = self.db.cursor()

        if public_username:

            cursor.execute(
                """
                SELECT login
                FROM accounts
                WHERE public_username=?
                AND login!=?
                """,
                (
                    public_username,
                    login
                )
            )

            if cursor.fetchone():
                return False, "username is already taken"

        cursor.execute(
            """
            SELECT password_salt,
                   password_hash
            FROM accounts
            WHERE login=?
            """,
            (
                login,
            )
        )

        row = cursor.fetchone()

        if not row:

            if not allow_registration:
                return False, "account does not exist"

            salt_hex = secrets.token_bytes(
                16
            ).hex()

            password_hash = self.hash_password(
                password,
                salt_hex
            )

            self.db.execute(
                """
                INSERT INTO accounts(
                    login,
                    password_salt,
                    password_hash,
                    node_id,
                    display_name,
                    public_username,
                    about,
                    avatar_data,
                    encryption_public_key,
                    email,
                    email_verified_at,
                    last_login
                )
                VALUES(
                    ?,?,?,?,?,?,?,?,?,?,
                    CASE WHEN ? THEN CURRENT_TIMESTAMP ELSE NULL END,
                    CURRENT_TIMESTAMP
                )
                """,
                (
                    login,
                    salt_hex,
                    password_hash,
                    node_id,
                    display_name,
                    public_username,
                    about,
                    avatar_data,
                    encryption_public_key,
                    self.normalize_email(email) if email_verified else "",
                    bool(email_verified),
                )
            )

            self.db.commit()

            print(
                f"Account registered: {login}"
            )

            return True, "registered"

        salt_hex, expected_hash = row

        password_hash = self.hash_password(
            password,
            salt_hex
        )

        if not secrets.compare_digest(
            password_hash,
            expected_hash
        ):
            return False, "bad login or password"

        if verify_only:

            return True, "ok"

        if self.is_account_device_revoked(login, node_id):

            if not reactivate_device:
                return False, "device session was revoked"

            self.reactivate_account_device(login, node_id)

        self.db.execute(
            """
            UPDATE accounts
            SET node_id=?,
                encryption_public_key=COALESCE(
                    ?,
                    encryption_public_key
                ),
                last_login=CURRENT_TIMESTAMP
            WHERE login=?
            """,
            (
                node_id,
                encryption_public_key,
                login
            )
        )

        self.db.commit()

        return True, "ok"

    def get_account_encryption_recovery(self, login):

        normalized_login = (
            login
            or ""
        ).strip().lower()

        if not normalized_login:
            return ""

        row = self.db.execute(
            """
            SELECT encryption_recovery
            FROM accounts
            WHERE login=?
            """,
            (
                normalized_login,
            )
        ).fetchone()

        return str(row[0] or "") if row else ""

    def delete_account(self, login, password):
        normalized_login = str(login or "").strip().lower()
        if not normalized_login or not self.verify_account_password(
            normalized_login,
            password,
        ):
            return False, "bad login or password"

        nodes = [
            row[0]
            for row in self.db.execute(
                "SELECT node_id FROM account_devices WHERE login=?",
                (normalized_login,),
            ).fetchall()
            if row[0]
        ]
        account_node = self.db.execute(
            "SELECT node_id FROM accounts WHERE login=?",
            (normalized_login,),
        ).fetchone()
        if account_node and account_node[0] and account_node[0] not in nodes:
            nodes.append(account_node[0])

        stored_paths = [
            row[0]
            for row in self.db.execute(
                """
                SELECT storage_path FROM server_files
                WHERE sender_login=? OR receiver_login=?
                UNION
                SELECT storage_path FROM file_transfer_sessions
                WHERE account_login=?
                """,
                (normalized_login, normalized_login, normalized_login),
            ).fetchall()
            if row[0]
        ]
        transfer_ids = [
            row[0]
            for row in self.db.execute(
                "SELECT transfer_id FROM file_transfer_sessions WHERE account_login=?",
                (normalized_login,),
            ).fetchall()
        ]

        owned_group_ids = []
        if nodes:
            placeholders = ",".join("?" for _ in nodes)
            owned_group_ids = [
                row[0]
                for row in self.db.execute(
                    f"SELECT group_id FROM server_groups WHERE owner_node IN ({placeholders})",
                    nodes,
                ).fetchall()
            ]

        with self.db:
            for group_id in owned_group_ids:
                self.db.execute(
                    "DELETE FROM server_group_keys WHERE group_id=?",
                    (group_id,),
                )
                self.db.execute(
                    "DELETE FROM server_group_messages WHERE group_id=?",
                    (group_id,),
                )
                self.db.execute(
                    "DELETE FROM server_files WHERE group_id=?",
                    (group_id,),
                )
                self.db.execute(
                    "DELETE FROM server_group_members WHERE group_id=?",
                    (group_id,),
                )
                self.db.execute(
                    "DELETE FROM server_groups WHERE group_id=?",
                    (group_id,),
                )

            for table, column in (
                ("sync_events", "account_login"),
                ("sync_event_state", "account_login"),
                ("sync_cursors", "account_login"),
                ("processed_mutations", "account_login"),
                ("account_devices", "login"),
                ("email_auth_challenges", "login"),
                ("account_email_trusted_devices", "login"),
                ("account_subscriptions", "login"),
                ("subscription_events", "login"),
                ("subscription_orders", "login"),
                ("boosty_telegram_links", "login"),
                ("vpn_peers", "login"),
                ("service_sessions", "login"),
                ("meshpro_usage", "login"),
                ("ai_voice_transcriptions", "login"),
                ("ai_image_ocr", "login"),
                ("web_push_subscriptions", "login"),
                ("file_transfer_sessions", "account_login"),
                ("file_transfer_chunks", "account_login"),
                ("server_sticker_libraries", "login"),
                ("android_push_tokens", "login"),
                ("account_chat_preferences", "login"),
                ("account_meshpro_preferences", "login"),
                ("scheduled_messages", "owner_login"),
            ):
                self.db.execute(
                    f"DELETE FROM {table} WHERE {column}=?",
                    (normalized_login,),
                )

            self.db.execute(
                "DELETE FROM direct_messages WHERE sender_login=? OR receiver_login=?",
                (normalized_login, normalized_login),
            )
            self.db.execute(
                "DELETE FROM server_files WHERE sender_login=? OR receiver_login=?",
                (normalized_login, normalized_login),
            )
            self.db.execute(
                "DELETE FROM server_group_messages WHERE sender_login=?",
                (normalized_login,),
            )
            self.db.execute(
                "DELETE FROM server_group_members WHERE login=?",
                (normalized_login,),
            )
            self.db.execute(
                "DELETE FROM server_group_keys WHERE member_login=?",
                (normalized_login,),
            )
            self.db.execute(
                "DELETE FROM server_chat_deletes WHERE owner_login=? OR peer_login=?",
                (normalized_login, normalized_login),
            )
            self.db.execute(
                "DELETE FROM server_reactions WHERE reactor_login=?",
                (normalized_login,),
            )
            self.db.execute(
                "DELETE FROM server_pins WHERE pinner_login=?",
                (normalized_login,),
            )
            story_ids = [
                row[0]
                for row in self.db.execute(
                    "SELECT story_id FROM server_stories WHERE owner_login=?",
                    (normalized_login,),
                ).fetchall()
            ]
            for story_id in story_ids:
                self.db.execute(
                    "DELETE FROM server_story_reactions WHERE story_id=?",
                    (story_id,),
                )
                self.db.execute(
                    "DELETE FROM server_story_views WHERE story_id=?",
                    (story_id,),
                )
            self.db.execute(
                "DELETE FROM server_stories WHERE owner_login=?",
                (normalized_login,),
            )
            self.db.execute(
                "DELETE FROM server_story_reactions WHERE reactor_login=?",
                (normalized_login,),
            )
            self.db.execute(
                "DELETE FROM server_story_views WHERE viewer_login=?",
                (normalized_login,),
            )
            if nodes:
                placeholders = ",".join("?" for _ in nodes)
                self.db.execute(
                    f"DELETE FROM offline_packets WHERE destination_node IN ({placeholders})",
                    nodes,
                )
            self.db.execute(
                "UPDATE boosty_activation_codes SET redeemed_login='' WHERE redeemed_login=?",
                (normalized_login,),
            )
            self.db.execute(
                "DELETE FROM accounts WHERE login=?",
                (normalized_login,),
            )
        for value in stored_paths:
            try:
                Path(value).unlink(missing_ok=True)
            except OSError:
                pass
        if hasattr(self, "_file_transfer_pending_path"):
            for transfer_id in transfer_ids:
                try:
                    shutil.rmtree(
                        self._file_transfer_pending_path(
                            normalized_login,
                            transfer_id,
                        ),
                        ignore_errors=True,
                    )
                except OSError:
                    pass
        return True, "ok"

    def change_account_password(
        self,
        login,
        current_password,
        new_password,
        encryption_recovery
    ):

        normalized_login = (
            login
            or ""
        ).strip().lower()
        current_password = current_password or ""
        new_password = new_password or ""

        if not normalized_login:
            return False, "account_not_found"

        if len(new_password) < 8:
            return False, "password_too_short"

        if len(new_password) > 256:
            return False, "password_too_long"

        if new_password == current_password:
            return False, "password_unchanged"

        if not self._valid_encryption_recovery(encryption_recovery):
            return False, "invalid_encryption_recovery"

        row = self.db.execute(
            """
            SELECT password_salt,
                   password_hash
            FROM accounts
            WHERE login=?
            """,
            (
                normalized_login,
            )
        ).fetchone()

        if not row:
            return False, "account_not_found"

        current_hash = self.hash_password(
            current_password,
            row[0]
        )

        if not secrets.compare_digest(current_hash, row[1]):
            return False, "invalid_current_password"

        salt_hex = secrets.token_bytes(16).hex()
        password_hash = self.hash_password(new_password, salt_hex)

        try:
            with self.db:
                self.db.execute(
                    """
                    UPDATE accounts
                    SET password_salt=?,
                        password_hash=?,
                        encryption_recovery=?,
                        last_login=CURRENT_TIMESTAMP
                    WHERE login=?
                    """,
                    (
                        salt_hex,
                        password_hash,
                        encryption_recovery,
                        normalized_login
                    )
                )
                self.db.execute(
                    """
                    UPDATE service_sessions
                    SET revoked_at=CURRENT_TIMESTAMP
                    WHERE login=?
                    """,
                    (
                        normalized_login,
                    )
                )
        except Exception:
            return False, "password_change_failed"

        return True, "ok"

    @staticmethod
    def _valid_encryption_recovery(value):

        if not isinstance(value, str) or not value or len(value) > 4096:
            return False

        try:
            payload = json.loads(value)
        except (TypeError, ValueError):
            return False

        if not isinstance(payload, dict) or payload.get("v") != 1:
            return False

        for field in ("s", "n", "c", "m"):
            item = payload.get(field)
            if not isinstance(item, str) or not item or len(item) > 512:
                return False

        return payload.get("i") == 300000

    def normalize_public_username(
        self,
        username
    ):

        username = (
            username
            or ""
        ).strip().lower().lstrip("@")

        username = re.sub(
            r"[^a-z0-9_]",
            "_",
            username
        ).strip("_")

        return username[:32]
