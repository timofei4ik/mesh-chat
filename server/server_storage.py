import json
import re
import sqlite3

try:
    from server.config import DB_PATH
except ModuleNotFoundError:
    from config import DB_PATH


class ServerStorageMixin:
    def _looks_like_node_id(
        self,
        node_id
    ):
        value = (node_id or "").strip()
        if not value:
            return False
        return re.match(
            r"^[0-9a-fA-F]{8}-"
            r"[0-9a-fA-F]{4}-"
            r"[0-9a-fA-F]{4}-"
            r"[0-9a-fA-F]{4}-"
            r"[0-9a-fA-F]{12}$",
            value
        ) is not None

    def _is_legacy_owner_placeholder(
        self,
        node_id
    ):
        value = (node_id or "").strip()
        return bool(value) and len(value) <= 12 and not self._looks_like_node_id(value)

    def open_db(self):

        DB_PATH.parent.mkdir(
            parents=True,
            exist_ok=True
        )

        conn = sqlite3.connect(
            DB_PATH,
            check_same_thread=False
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS offline_packets(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                destination_node TEXT NOT NULL,
                packet_json TEXT NOT NULL,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS accounts(
                login TEXT PRIMARY KEY,
                password_salt TEXT NOT NULL,
                password_hash TEXT NOT NULL,
                node_id TEXT,
                display_name TEXT,
                public_username TEXT,
                about TEXT,
                avatar_data TEXT,
                encryption_public_key TEXT,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                last_login DATETIME
            )
            """
        )

        cursor = conn.execute(
            "PRAGMA table_info(accounts)"
        )

        account_columns = {
            row[1]
            for row in cursor.fetchall()
        }

        if "about" not in account_columns:

            conn.execute(
                "ALTER TABLE accounts ADD COLUMN about TEXT"
            )

        if "public_username" not in account_columns:

            conn.execute(
                "ALTER TABLE accounts ADD COLUMN public_username TEXT"
            )

        if "avatar_data" not in account_columns:

            conn.execute(
                "ALTER TABLE accounts ADD COLUMN avatar_data TEXT"
            )

        if "encryption_public_key" not in account_columns:

            conn.execute(
                "ALTER TABLE accounts ADD COLUMN encryption_public_key TEXT"
            )

        conn.execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_public_username
            ON accounts(public_username)
            WHERE public_username IS NOT NULL
            AND public_username != ''
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS account_devices(
                login TEXT NOT NULL,
                node_id TEXT NOT NULL,
                display_name TEXT,
                app_version TEXT,
                online INTEGER NOT NULL DEFAULT 0,
                last_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(login, node_id)
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS web_push_subscriptions(
                endpoint TEXT PRIMARY KEY,
                login TEXT,
                node_id TEXT NOT NULL,
                subscription_json TEXT NOT NULL,
                user_agent TEXT,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS direct_messages(
                message_id TEXT PRIMARY KEY,
                sender_node TEXT,
                sender_login TEXT,
                sender_name TEXT,
                receiver_node TEXT,
                receiver_login TEXT,
                message TEXT,
                reply_to_message_id TEXT,
                reply_to_text TEXT,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )
        cursor = conn.execute(
            "PRAGMA table_info(direct_messages)"
        )
        direct_columns = {
            row[1] for row in cursor.fetchall()
        }
        if "reply_to_message_id" not in direct_columns:
            conn.execute(
                "ALTER TABLE direct_messages ADD COLUMN reply_to_message_id TEXT"
            )
        if "reply_to_text" not in direct_columns:
            conn.execute(
                "ALTER TABLE direct_messages ADD COLUMN reply_to_text TEXT"
            )
        if "chat_kind" not in direct_columns:
            conn.execute(
                "ALTER TABLE direct_messages ADD COLUMN chat_kind TEXT DEFAULT 'normal'"
            )
        if "chat_id" not in direct_columns:
            conn.execute(
                "ALTER TABLE direct_messages ADD COLUMN chat_id TEXT DEFAULT ''"
            )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS server_groups(
                group_id TEXT PRIMARY KEY,
                group_name TEXT,
                group_about TEXT DEFAULT '',
                group_avatar_data TEXT DEFAULT '',
                members_json TEXT,
                owner_node TEXT,
                admins_json TEXT DEFAULT '[]',
                is_channel INTEGER DEFAULT 0,
                comments_enabled INTEGER DEFAULT 1,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        cursor = conn.execute(
            "PRAGMA table_info(server_groups)"
        )

        group_columns = {
            row[1]
            for row in cursor.fetchall()
        }

        if "owner_node" not in group_columns:

            conn.execute(
                "ALTER TABLE server_groups ADD COLUMN owner_node TEXT"
            )

        if "group_about" not in group_columns:

            conn.execute(
                "ALTER TABLE server_groups ADD COLUMN group_about TEXT DEFAULT ''"
            )

        if "group_avatar_data" not in group_columns:

            conn.execute(
                "ALTER TABLE server_groups ADD COLUMN group_avatar_data TEXT DEFAULT ''"
            )

        if "admins_json" not in group_columns:

            conn.execute(
                "ALTER TABLE server_groups ADD COLUMN admins_json TEXT DEFAULT '[]'"
            )

        if "is_channel" not in group_columns:

            conn.execute(
                "ALTER TABLE server_groups ADD COLUMN is_channel INTEGER DEFAULT 0"
            )

        if "comments_enabled" not in group_columns:

            conn.execute(
                "ALTER TABLE server_groups ADD COLUMN comments_enabled INTEGER DEFAULT 1"
            )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS server_group_members(
                group_id TEXT,
                node_id TEXT,
                login TEXT,
                PRIMARY KEY(group_id, node_id)
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS server_group_keys(
                group_id TEXT,
                key_id TEXT,
                member_node TEXT,
                member_login TEXT,
                key_envelope TEXT NOT NULL,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(group_id, key_id, member_node)
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS server_group_messages(
                message_id TEXT PRIMARY KEY,
                group_id TEXT,
                group_name TEXT,
                sender_node TEXT,
                sender_login TEXT,
                sender_name TEXT,
                message TEXT,
                reply_to_message_id TEXT,
                reply_to_text TEXT,
                members_json TEXT,
                group_key_id TEXT,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS server_chat_deletes(
                owner_node TEXT NOT NULL,
                peer_node TEXT NOT NULL,
                chat_kind TEXT DEFAULT 'normal',
                chat_id TEXT DEFAULT '',
                deleted_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(owner_node, peer_node, chat_kind, chat_id)
            )
            """
        )
        cursor = conn.execute(
            "PRAGMA table_info(server_chat_deletes)"
        )
        chat_delete_columns = {
            row[1] for row in cursor.fetchall()
        }
        if "chat_kind" not in chat_delete_columns:
            conn.execute(
                "ALTER TABLE server_chat_deletes ADD COLUMN chat_kind TEXT DEFAULT 'normal'"
            )
        if "chat_id" not in chat_delete_columns:
            conn.execute(
                "ALTER TABLE server_chat_deletes ADD COLUMN chat_id TEXT DEFAULT ''"
            )
        cursor = conn.execute(
            "PRAGMA table_info(server_chat_deletes)"
        )
        chat_delete_pk = [
            row[1]
            for row in sorted(
                cursor.fetchall(),
                key=lambda item: item[5]
            )
            if row[5]
        ]
        if chat_delete_pk == ["owner_node", "peer_node"]:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS server_chat_deletes_new(
                    owner_node TEXT NOT NULL,
                    peer_node TEXT NOT NULL,
                    chat_kind TEXT DEFAULT 'normal',
                    chat_id TEXT DEFAULT '',
                    deleted_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY(owner_node, peer_node, chat_kind, chat_id)
                )
                """
            )
            conn.execute(
                """
                INSERT OR IGNORE INTO server_chat_deletes_new(
                    owner_node,
                    peer_node,
                    chat_kind,
                    chat_id,
                    deleted_at
                )
                SELECT owner_node,
                       peer_node,
                       COALESCE(chat_kind, 'normal'),
                       COALESCE(chat_id, ''),
                       deleted_at
                FROM server_chat_deletes
                """
            )
            conn.execute("DROP TABLE server_chat_deletes")
            conn.execute(
                "ALTER TABLE server_chat_deletes_new RENAME TO server_chat_deletes"
            )

        cursor = conn.execute(
            "PRAGMA table_info(server_group_messages)"
        )
        if "group_key_id" not in {
            row[1] for row in cursor.fetchall()
        }:
            conn.execute(
                "ALTER TABLE server_group_messages ADD COLUMN group_key_id TEXT"
            )
        cursor = conn.execute(
            "PRAGMA table_info(server_group_messages)"
        )
        group_message_columns = {
            row[1] for row in cursor.fetchall()
        }
        if "reply_to_message_id" not in group_message_columns:
            conn.execute(
                "ALTER TABLE server_group_messages ADD COLUMN reply_to_message_id TEXT"
            )
        if "reply_to_text" not in group_message_columns:
            conn.execute(
                "ALTER TABLE server_group_messages ADD COLUMN reply_to_text TEXT"
            )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS server_reactions(
                scope TEXT,
                message_id TEXT,
                reactor_node TEXT,
                reactor_login TEXT,
                reaction TEXT,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(scope, message_id, reactor_node, reaction)
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS server_files(
                file_id TEXT PRIMARY KEY,
                sender_node TEXT,
                sender_login TEXT,
                sender_name TEXT,
                receiver_node TEXT,
                receiver_login TEXT,
                group_id TEXT,
                filename TEXT,
                caption TEXT,
                data TEXT,
                group_key_id TEXT,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS server_pins(
                scope TEXT,
                message_id TEXT,
                pinner_node TEXT,
                pinner_login TEXT,
                text TEXT,
                group_key_id TEXT,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(scope, message_id)
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS server_stories(
                story_id TEXT PRIMARY KEY,
                owner_node TEXT,
                owner_login TEXT,
                story_json TEXT NOT NULL,
                recipients_json TEXT DEFAULT '[]',
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS server_story_reactions(
                story_id TEXT,
                reactor_node TEXT,
                reactor_login TEXT,
                reaction TEXT,
                liked INTEGER DEFAULT 1,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(story_id, reactor_node, reaction)
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS server_story_views(
                story_id TEXT,
                viewer_node TEXT,
                viewer_login TEXT,
                viewed_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(story_id, viewer_node)
            )
            """
        )

        cursor = conn.execute(
            "PRAGMA table_info(server_pins)"
        )
        if "group_key_id" not in {
            row[1] for row in cursor.fetchall()
        }:
            conn.execute(
                "ALTER TABLE server_pins ADD COLUMN group_key_id TEXT"
            )

        cursor = conn.execute(
            "PRAGMA table_info(server_files)"
        )
        if "group_key_id" not in {
            row[1] for row in cursor.fetchall()
        }:
            conn.execute(
                "ALTER TABLE server_files ADD COLUMN group_key_id TEXT"
            )

        cursor = conn.execute(
            "PRAGMA table_info(server_files)"
        )
        if "caption" not in {
            row[1] for row in cursor.fetchall()
        }:
            conn.execute(
                "ALTER TABLE server_files ADD COLUMN caption TEXT"
            )
        cursor = conn.execute(
            "PRAGMA table_info(server_files)"
        )
        file_columns = {
            row[1] for row in cursor.fetchall()
        }
        if "chat_kind" not in file_columns:
            conn.execute(
                "ALTER TABLE server_files ADD COLUMN chat_kind TEXT DEFAULT 'normal'"
            )
        if "chat_id" not in file_columns:
            conn.execute(
                "ALTER TABLE server_files ADD COLUMN chat_id TEXT DEFAULT ''"
            )

        conn.commit()

        return conn

    def save_web_push_subscription(
        self,
        login,
        node_id,
        subscription,
        user_agent=""
    ):

        if not node_id or not isinstance(subscription, dict):
            return

        endpoint = subscription.get("endpoint")

        if not endpoint:
            return

        self.db.execute(
            """
            INSERT INTO web_push_subscriptions(
                endpoint,
                login,
                node_id,
                subscription_json,
                user_agent,
                updated_at
            )
            VALUES(?,?,?,?,?,CURRENT_TIMESTAMP)
            ON CONFLICT(endpoint) DO UPDATE SET
                login=excluded.login,
                node_id=excluded.node_id,
                subscription_json=excluded.subscription_json,
                user_agent=excluded.user_agent,
                updated_at=CURRENT_TIMESTAMP
            """,
            (
                endpoint,
                login,
                node_id,
                json.dumps(subscription, ensure_ascii=False),
                user_agent or ""
            )
        )

        self.db.commit()

    def delete_web_push_subscription(
        self,
        endpoint=None,
        node_id=None
    ):

        if endpoint:
            self.db.execute(
                "DELETE FROM web_push_subscriptions WHERE endpoint=?",
                (endpoint,)
            )
        elif node_id:
            self.db.execute(
                "DELETE FROM web_push_subscriptions WHERE node_id=?",
                (node_id,)
            )
        else:
            return

        self.db.commit()

    def web_push_subscriptions_for_node(
        self,
        node_id
    ):

        if not node_id:
            return []

        cursor = self.db.execute(
            """
            SELECT endpoint, subscription_json
            FROM web_push_subscriptions
            WHERE node_id=?
            """,
            (node_id,)
        )

        rows = []

        for endpoint, subscription_json in cursor.fetchall():
            try:
                rows.append(
                    (
                        endpoint,
                        json.loads(subscription_json)
                    )
                )
            except json.JSONDecodeError:
                self.delete_web_push_subscription(endpoint=endpoint)

        return rows

    def save_account_device(
        self,
        login,
        node_id,
        display_name=None,
        app_version=None,
        online=True
    ):

        login = (
            login
            or ""
        ).strip().lower()

        if not login or not node_id:
            return

        self.db.execute(
            """
            INSERT INTO account_devices(
                login,
                node_id,
                display_name,
                app_version,
                online,
                last_seen
            )
            VALUES(?,?,?,?,?,CURRENT_TIMESTAMP)
            ON CONFLICT(login, node_id) DO UPDATE SET
                display_name=COALESCE(excluded.display_name, display_name),
                app_version=COALESCE(excluded.app_version, app_version),
                online=excluded.online,
                last_seen=CURRENT_TIMESTAMP
            """,
            (
                login,
                node_id,
                display_name,
                app_version,
                1 if online else 0
            )
        )

        self.db.commit()

    def set_account_device_online(
        self,
        login,
        node_id,
        online
    ):

        login = (
            login
            or ""
        ).strip().lower()

        if not login or not node_id:
            return

        self.db.execute(
            """
            UPDATE account_devices
            SET online=?,
                last_seen=CURRENT_TIMESTAMP
            WHERE login=?
              AND node_id=?
            """,
            (
                1 if online else 0,
                login,
                node_id
            )
        )

        self.db.commit()

    def get_account_devices(
        self,
        login
    ):

        login = (
            login
            or ""
        ).strip().lower()

        if not login:
            return []

        cursor = self.db.cursor()
        cursor.execute(
            """
            SELECT node_id,
                   display_name,
                   app_version,
                   online,
                   last_seen
            FROM account_devices
            WHERE login=?
            ORDER BY online DESC,
                     last_seen DESC
            """,
            (
                login,
            )
        )

        return [
            {
                "node_id": row[0],
                "display_name": row[1],
                "app_version": row[2],
                "online": bool(row[3]),
                "last_seen": row[4]
            }
            for row in cursor.fetchall()
        ]

    def get_online_account_nodes(
        self,
        login
    ):

        login = (
            login
            or ""
        ).strip().lower()

        if not login:
            return []

        cursor = self.db.cursor()
        cursor.execute(
            """
            SELECT node_id
            FROM account_devices
            WHERE login=?
              AND online=1
            ORDER BY last_seen DESC
            """,
            (
                login,
            )
        )

        return [
            row[0]
            for row in cursor.fetchall()
            if row[0]
        ]

    def save_account_profile(
        self,
        login,
        node_id,
        display_name,
        public_username=None,
        about=None,
        avatar_data=None,
        encryption_public_key=None
    ):

        login = (
            login
            or self.get_login_by_node(node_id)
            or ""
        ).strip().lower()

        if not login:
            return

        if public_username is not None:

            public_username = (
                public_username
                or ""
            ).strip().lower().lstrip("@")

            cursor = self.db.cursor()
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
                print(
                    f"Username update rejected, already taken: {public_username}"
                )
                return False, "username is already taken"

        self.db.execute(
            """
            UPDATE accounts
            SET node_id=?,
                display_name=COALESCE(?, display_name),
                public_username=COALESCE(?, public_username),
                about=COALESCE(?, about),
                avatar_data=COALESCE(?, avatar_data),
                encryption_public_key=COALESCE(
                    ?,
                    encryption_public_key
                ),
                last_login=CURRENT_TIMESTAMP
            WHERE login=?
            """,
            (
                node_id,
                display_name,
                public_username,
                about,
                avatar_data,
                encryption_public_key,
                login
            )
        )

        self.db.commit()
        return True, "ok"

    def find_account_by_public_username(
        self,
        public_username
    ):

        username = (
            public_username
            or ""
        ).strip().lower().lstrip("@")

        if not username:
            return None

        cursor = self.db.cursor()
        cursor.execute(
            """
            SELECT a.login,
                   COALESCE(d.node_id, a.node_id) AS node_id,
                   a.display_name,
                   a.public_username,
                   a.about,
                   a.avatar_data,
                   a.encryption_public_key
            FROM accounts a
            LEFT JOIN account_devices d
              ON d.login=a.login
             AND d.node_id=(
                SELECT d2.node_id
                FROM account_devices d2
                WHERE d2.login=a.login
                ORDER BY d2.online DESC,
                         d2.last_seen DESC
                LIMIT 1
             )
            WHERE a.public_username=?
            """,
            (
                username,
            )
        )

        row = cursor.fetchone()

        if not row:
            return None

        return {
            "login": row[0],
            "node_id": row[1],
            "display_name": row[2],
            "public_username": row[3],
            "about": row[4],
            "avatar_data": row[5]
            ,"encryption_public_key": row[6]
        }

    def get_login_by_node(
        self,
        node_id
    ):

        cursor = self.db.cursor()

        cursor.execute(
            """
            SELECT login
            FROM accounts
            WHERE node_id=?
            """,
            (
                node_id,
            )
        )

        row = cursor.fetchone()

        if row:
            return row[0]

        cursor.execute(
            """
            SELECT login
            FROM account_devices
            WHERE node_id=?
            """,
            (
                node_id,
            )
        )

        row = cursor.fetchone()

        if row:
            return row[0]

        return None

    def get_profile_by_node(
        self,
        node_id
    ):

        cursor = self.db.cursor()

        cursor.execute(
            """
            SELECT a.login,
                   ? AS node_id,
                   a.display_name,
                   a.public_username,
                   a.about,
                   a.avatar_data,
                   a.encryption_public_key
            FROM accounts a
            LEFT JOIN account_devices d
              ON d.login=a.login
            WHERE a.node_id=? OR d.node_id=?
            LIMIT 1
            """,
            (
                node_id,
                node_id,
                node_id,
            )
        )

        row = cursor.fetchone()

        if not row:
            return {}

        return {
            "login": row[0],
            "node_id": row[1],
            "display_name": row[2],
            "public_username": row[3],
            "about": row[4],
            "avatar_data": row[5]
            ,"encryption_public_key": row[6]
        }

    def save_group_members(
        self,
        group_id,
        group_name,
        members,
        owner_node=None,
        admins=None,
        is_channel=False,
        comments_enabled=True,
        group_about=None,
        group_avatar_data=None
    ):

        if not group_id:
            return

        members = list(
            dict.fromkeys(
                members or []
            )
        )

        existing_owner, existing_admins = self.get_group_roles(
            group_id
        )

        existing_meta = self.db.execute(
            """
            SELECT group_about,
                   group_avatar_data,
                   COALESCE(comments_enabled, 1)
            FROM server_groups
            WHERE group_id=?
            """,
            (
                group_id,
            )
        ).fetchone()
        existing_about = existing_meta[0] if existing_meta else ""
        existing_avatar = existing_meta[1] if existing_meta else ""
        existing_comments_enabled = (
            existing_meta[2] == 1
            if existing_meta
            else True
        )
        if comments_enabled is None:
            comments_enabled = existing_comments_enabled
        group_about = (
            group_about
            if group_about not in (None, "")
            else existing_about
        )
        group_avatar_data = (
            group_avatar_data
            if group_avatar_data not in (None, "")
            else existing_avatar
        )

        owner_node = (
            existing_owner
            or owner_node
            or ""
        )

        if owner_node and owner_node not in members:
            members.append(owner_node)

        if admins is None:
            admins = existing_admins

        admins = [
            node_id
            for node_id in dict.fromkeys(
                admins or []
            )
            if node_id in members
            and node_id != owner_node
        ]

        self.db.execute(
            """
            INSERT OR REPLACE INTO server_groups(
                group_id,
                group_name,
                group_about,
                group_avatar_data,
                members_json,
                owner_node,
                admins_json,
                is_channel,
                comments_enabled,
                updated_at
            )
            VALUES(?,?,?,?,?,?,?,?,?,CURRENT_TIMESTAMP)
            """,
            (
                group_id,
                group_name or group_id,
                group_about or "",
                group_avatar_data or "",
                json.dumps(
                    members,
                    ensure_ascii=False
                ),
                owner_node,
                json.dumps(
                    admins,
                    ensure_ascii=False
                ),
                1 if is_channel else 0,
                1 if comments_enabled else 0
            )
        )

        self.db.execute(
            """
            DELETE FROM server_group_members
            WHERE group_id=?
            """,
            (
                group_id,
            )
        )

        for member in members:

            self.db.execute(
                """
                INSERT OR REPLACE INTO server_group_members(
                    group_id,
                    node_id,
                    login
                )
                VALUES(?,?,?)
                """,
                (
                    group_id,
                    member,
                    self.get_login_by_node(
                        member
                    )
                )
            )

        self.db.commit()

    def get_group_roles(
        self,
        group_id
    ):

        cursor = self.db.cursor()

        cursor.execute(
            """
            SELECT owner_node,
                   admins_json,
                   members_json
            FROM server_groups
            WHERE group_id=?
            """,
            (
                group_id,
            )
        )

        row = cursor.fetchone()

        if not row:
            return "", []

        owner_node = row[0] or ""
        if self._is_legacy_owner_placeholder(owner_node):
            owner_node = ""

        try:
            admins = json.loads(
                row[1] or "[]"
            )
        except (TypeError, ValueError):
            admins = []

        return owner_node, admins

    def authorize_group_management(
        self,
        packet
    ):

        packet_type = packet.get(
            "type"
        )

        if packet_type not in (
            "group_update",
            "group_delete",
            "group_pin",
            "group_member_leave"
        ):
            return True

        group_id = packet.get(
            "group_id"
        )

        source_node = packet.get(
            "source_node"
        )

        owner_node, admins = self.get_group_roles(
            group_id
        )

        if packet_type == "group_member_leave":
            return (
                bool(source_node)
                and (
                    packet.get("leaver_node") in (None, "", source_node)
                )
            )

        if not owner_node:

            claimed_owner = packet.get(
                "owner_node"
            )
            source_is_member = self.db.execute(
                """
                SELECT 1
                FROM server_group_members
                WHERE group_id=? AND node_id=?
                LIMIT 1
                """,
                (
                    group_id,
                    source_node
                )
            ).fetchone() is not None

            if packet_type == "group_delete":
                return source_is_member

            return (
                packet_type == "group_update"
                and source_node
                and (
                    source_node == claimed_owner
                    or source_is_member
                )
            )

        if packet_type == "group_delete":
            return source_node == owner_node

        if packet_type == "group_member_leave":
            return True

        if packet_type == "group_pin":
            return (
                source_node == owner_node
                or source_node in admins
            )

        members = packet.get(
            "members"
        ) or []

        claimed_owner = packet.get(
            "owner_node"
        )

        claimed_admins = packet.get(
            "admins"
        ) or []

        if (
            claimed_owner != owner_node
            or owner_node not in members
        ):
            return False

        if source_node == owner_node:
            return True

        if source_node not in admins:
            return False

        return (
            set(claimed_admins) == set(admins)
            and all(
                admin_node in members
                for admin_node in admins
            )
        )

    def save_history_packet(
        self,
        packet
    ):

        packet_type = packet.get("type")

        self.save_group_key_envelopes(
            packet
        )

        if packet_type == "chat_message":

            message_id = packet.get("packet_id")

            if not message_id:
                return

            sender_node = packet.get("source_node")
            receiver_node = packet.get("destination_node")

            self.db.execute(
                """
                INSERT OR IGNORE INTO direct_messages(
                    message_id,
                    sender_node,
                    sender_login,
                    sender_name,
                    receiver_node,
                    receiver_login,
                    message,
                    reply_to_message_id,
                    reply_to_text,
                    chat_kind,
                    chat_id,
                    created_at
                )
                VALUES(?,?,?,?,?,?,?,?,?,?,?,STRFTIME(
                    '%Y-%m-%d %H:%M:%f',
                    'now'
                ))
                """,
                (
                    message_id,
                    sender_node,
                    self.get_login_by_node(sender_node),
                    packet.get("sender") or sender_node,
                    receiver_node,
                    self.get_login_by_node(receiver_node),
                    packet.get("message") or "",
                    packet.get("reply_to_message_id"),
                    packet.get("reply_to_text"),
                    packet.get("chat_kind") or "normal",
                    packet.get("chat_id") or ""
                )
            )

            self.db.commit()

        elif packet_type == "profile_update":

            self.save_account_profile(
                packet.get("login"),
                packet.get("source_node"),
                packet.get("display_name"),
                packet.get("public_username"),
                packet.get("about"),
                packet.get("avatar_data"),
                packet.get("encryption_public_key")
            )

        elif packet_type == "story_update":

            story = packet.get("story")
            if not isinstance(story, dict):
                return

            story_id = story.get("id") or packet.get("packet_id")
            owner_node = story.get("owner_node") or packet.get("source_node")
            destination_node = packet.get("destination_node")

            if not story_id or not owner_node:
                return

            cursor = self.db.cursor()
            cursor.execute(
                """
                SELECT recipients_json
                FROM server_stories
                WHERE story_id=?
                """,
                (
                    story_id,
                )
            )
            row = cursor.fetchone()
            recipients = set()
            if row:
                try:
                    recipients.update(json.loads(row[0] or "[]"))
                except json.JSONDecodeError:
                    pass
            if destination_node and destination_node != "SERVER":
                recipients.add(destination_node)
            recipients.add(owner_node)

            self.db.execute(
                """
                INSERT INTO server_stories(
                    story_id,
                    owner_node,
                    owner_login,
                    story_json,
                    recipients_json,
                    created_at
                )
                VALUES(?,?,?,?,?,STRFTIME('%Y-%m-%d %H:%M:%f','now'))
                ON CONFLICT(story_id) DO UPDATE SET
                    story_json=excluded.story_json,
                    recipients_json=excluded.recipients_json
                """,
                (
                    story_id,
                    owner_node,
                    self.get_login_by_node(owner_node),
                    json.dumps(story, ensure_ascii=False),
                    json.dumps(sorted(recipients), ensure_ascii=False)
                )
            )

            self.db.commit()

        elif packet_type == "story_reaction":

            story_id = packet.get("story_id")
            reactor_node = packet.get("source_node")
            reaction = packet.get("reaction") or "heart"

            if not story_id or not reactor_node:
                return

            if packet.get("liked") is False:
                self.db.execute(
                    """
                    DELETE FROM server_story_reactions
                    WHERE story_id=?
                      AND reactor_node=?
                      AND reaction=?
                    """,
                    (
                        story_id,
                        reactor_node,
                        reaction
                    )
                )
            else:
                self.db.execute(
                    """
                    INSERT INTO server_story_reactions(
                        story_id,
                        reactor_node,
                        reactor_login,
                        reaction,
                        liked,
                        created_at
                    )
                    VALUES(?,?,?,?,1,CURRENT_TIMESTAMP)
                    ON CONFLICT(story_id, reactor_node, reaction)
                    DO UPDATE SET
                        liked=1,
                        created_at=CURRENT_TIMESTAMP
                    """,
                    (
                        story_id,
                        reactor_node,
                        self.get_login_by_node(reactor_node),
                        reaction
                    )
                )

            self.db.commit()

        elif packet_type == "story_view":

            story_id = packet.get("story_id")
            viewer_node = packet.get("source_node")

            if not story_id or not viewer_node:
                return

            self.db.execute(
                """
                INSERT INTO server_story_views(
                    story_id,
                    viewer_node,
                    viewer_login,
                    viewed_at
                )
                VALUES(?,?,?,CURRENT_TIMESTAMP)
                ON CONFLICT(story_id, viewer_node)
                DO UPDATE SET
                    viewed_at=CURRENT_TIMESTAMP
                """,
                (
                    story_id,
                    viewer_node,
                    self.get_login_by_node(viewer_node)
                )
            )

            self.db.commit()

        elif packet_type == "story_delete":

            story_id = packet.get("story_id")
            owner_node = packet.get("source_node")

            if not story_id or not owner_node:
                return

            cursor = self.db.cursor()
            cursor.execute(
                """
                SELECT owner_node
                FROM server_stories
                WHERE story_id=?
                """,
                (
                    story_id,
                )
            )
            row = cursor.fetchone()
            if row and row[0] != owner_node:
                return

            self.db.execute(
                "DELETE FROM server_stories WHERE story_id=?",
                (
                    story_id,
                )
            )
            self.db.execute(
                "DELETE FROM server_story_reactions WHERE story_id=?",
                (
                    story_id,
                )
            )
            self.db.execute(
                "DELETE FROM server_story_views WHERE story_id=?",
                (
                    story_id,
                )
            )

            self.db.commit()

        elif packet_type == "message_edit":

            message_id = packet.get(
                "message_id"
            )

            message = packet.get(
                "message"
            )

            file_caption = packet.get(
                "file_caption"
            )

            sender_node = packet.get(
                "source_node"
            )

            if not message_id or message is None:
                return

            self.db.execute(
                """
                UPDATE direct_messages
                SET message=?
                WHERE message_id=?
                AND sender_node=?
                """,
                (
                    file_caption if file_caption is not None else message,
                    message_id,
                    sender_node
                )
            )

            self.db.execute(
                """
                UPDATE server_files
                SET caption=?
                WHERE file_id=?
                AND sender_node=?
                """,
                (
                    message,
                    message_id,
                    sender_node
                )
            )

            self.db.commit()

        elif packet_type == "message_delete":

            message_id = packet.get(
                "message_id"
            )

            sender_node = packet.get(
                "source_node"
            )

            if not message_id:
                return

            self.db.execute(
                """
                DELETE FROM direct_messages
                WHERE message_id=?
                AND sender_node=?
                """,
                (
                    message_id,
                    sender_node
                )
            )

            self.db.execute(
                """
                DELETE FROM server_reactions
                WHERE scope='direct'
                AND message_id=?
                """,
                (
                    message_id,
                )
            )

            self.db.execute(
                """
                DELETE FROM server_files
                WHERE file_id=?
                AND sender_node=?
                """,
                (
                    message_id,
                    sender_node
                )
            )

            self.db.execute(
                """
                DELETE FROM server_pins
                WHERE message_id=?
                """,
                (
                    message_id,
                )
            )

            self.db.commit()

        elif packet_type == "chat_delete":

            source_node = packet.get("source_node")
            destination_node = packet.get("destination_node")
            chat_node_id = packet.get("chat_node_id") or destination_node
            chat_kind = packet.get("chat_kind") or "normal"
            chat_id = packet.get("chat_id") or ""

            if not source_node or not destination_node:
                return

            for owner_node, peer_node in (
                (source_node, chat_node_id),
                (destination_node, source_node)
            ):

                self.db.execute(
                    """
                    INSERT OR REPLACE INTO server_chat_deletes(
                        owner_node,
                        peer_node,
                        chat_kind,
                        chat_id,
                        deleted_at
                    )
                    VALUES(?,?,?,?,STRFTIME(
                        '%Y-%m-%d %H:%M:%f',
                        'now'
                    ))
                    """,
                    (
                        owner_node,
                        peer_node,
                        chat_kind,
                        chat_id
                    )
                )

            self.db.commit()

        elif packet_type in (
            "message_pin",
            "group_pin"
        ):

            message_id = packet.get(
                "message_id"
            )
            source_node = packet.get(
                "source_node"
            )

            if not message_id or not source_node:
                return

            scope = (
                f"group:{packet.get('group_id')}"
                if packet_type == "group_pin"
                else "chat:" + ":".join(
                    sorted(
                        (
                            source_node,
                            packet.get("destination_node") or ""
                        )
                    )
                )
            )

            if packet.get("action") == "unpin":

                self.db.execute(
                    """
                    DELETE FROM server_pins
                    WHERE scope=?
                      AND message_id=?
                    """,
                    (
                        scope,
                        message_id
                    )
                )

            else:

                self.db.execute(
                    """
                    INSERT INTO server_pins(
                        scope,
                        message_id,
                        pinner_node,
                        pinner_login,
                        text,
                        group_key_id,
                        created_at
                    )
                    VALUES(?,?,?,?,?,?,CURRENT_TIMESTAMP)
                    ON CONFLICT(scope, message_id) DO UPDATE SET
                        pinner_node=excluded.pinner_node,
                        pinner_login=excluded.pinner_login,
                        text=excluded.text,
                        group_key_id=excluded.group_key_id,
                        created_at=CURRENT_TIMESTAMP
                    """,
                    (
                        scope,
                        message_id,
                        source_node,
                        self.get_login_by_node(source_node),
                        packet.get("text") or "",
                        packet.get("group_key_id")
                    )
                )

            self.db.commit()

        elif packet_type == "group_message":

            group_id = packet.get("group_id")
            group_name = packet.get("group_name") or group_id
            members = packet.get("members") or []

            existing_owner, _ = self.get_group_roles(
                group_id
            )

            if not existing_owner:
                claimed_owner = packet.get("owner_node") or packet.get("source_node")

                self.save_group_members(
                    group_id,
                    group_name,
                    members,
                    claimed_owner,
                    packet.get("admins"),
                    packet.get("is_channel") is True,
                    packet.get("comments_enabled"),
                    packet.get("group_about"),
                    packet.get("group_avatar_data")
                )

            message_id = (
                packet.get("group_message_id")
                or packet.get("packet_id")
            )

            if not message_id:
                return

            sender_node = packet.get("source_node")

            self.db.execute(
                """
                INSERT OR IGNORE INTO server_group_messages(
                    message_id,
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
                    created_at
                )
                VALUES(?,?,?,?,?,?,?,?,?,?,?,STRFTIME(
                    '%Y-%m-%d %H:%M:%f',
                    'now'
                ))
                """,
                (
                    message_id,
                    group_id,
                    group_name,
                    sender_node,
                    self.get_login_by_node(sender_node),
                    packet.get("sender") or sender_node,
                    packet.get("message") or "",
                    packet.get("reply_to_message_id"),
                    packet.get("reply_to_text"),
                    json.dumps(members, ensure_ascii=False),
                    packet.get("group_key_id")
                )
            )

            self.db.commit()

        elif packet_type == "group_update":

            self.save_group_members(
                packet.get("group_id"),
                packet.get("group_name"),
                packet.get("members") or [],
                packet.get("owner_node"),
                packet.get("admins"),
                packet.get("is_channel") is True,
                packet.get("comments_enabled"),
                packet.get("group_about"),
                packet.get("group_avatar_data")
            )

        elif packet_type == "group_member_leave":

            group_id = packet.get("group_id")
            leaver_node = (
                packet.get("leaver_node")
                or packet.get("source_node")
            )

            if not group_id or not leaver_node:
                return

            row = self.db.execute(
                """
                SELECT group_name,
                       group_about,
                       group_avatar_data,
                       members_json,
                       owner_node,
                       admins_json,
                       is_channel,
                       COALESCE(comments_enabled, 1)
                FROM server_groups
                WHERE group_id=?
                """,
                (
                    group_id,
                )
            ).fetchone()

            if not row:
                return

            try:
                members = json.loads(row[3] or "[]")
            except (TypeError, ValueError):
                members = []

            try:
                admins = json.loads(row[5] or "[]")
            except (TypeError, ValueError):
                admins = []

            members = [
                member
                for member in members
                if member != leaver_node
            ]
            admins = [
                admin
                for admin in admins
                if admin != leaver_node
            ]

            self.save_group_members(
                group_id,
                row[0],
                members,
                row[4],
                admins,
                row[6] == 1,
                row[7] == 1,
                row[1],
                row[2]
            )

        elif packet_type == "group_delete":

            group_id = packet.get(
                "group_id"
            )

            if not group_id:
                return

            self.db.execute(
                """
                DELETE FROM server_reactions
                WHERE scope=?
                """,
                (
                    f"group:{group_id}",
                )
            )

            self.db.execute(
                """
                DELETE FROM server_files
                WHERE group_id=?
                """,
                (
                    group_id,
                )
            )

            self.db.execute(
                """
                DELETE FROM server_group_messages
                WHERE group_id=?
                """,
                (
                    group_id,
                )
            )

            self.db.execute(
                """
                DELETE FROM server_group_members
                WHERE group_id=?
                """,
                (
                    group_id,
                )
            )

            self.db.execute(
                """
                DELETE FROM server_group_keys
                WHERE group_id=?
                """,
                (
                    group_id,
                )
            )

            self.db.execute(
                """
                DELETE FROM server_pins
                WHERE scope=?
                """,
                (
                    f"group:{group_id}",
                )
            )

            self.db.execute(
                """
                DELETE FROM server_groups
                WHERE group_id=?
                """,
                (
                    group_id,
                )
            )

            self.db.commit()

        elif packet_type == "group_message_edit":

            message_id = packet.get(
                "group_message_id"
            )

            message = packet.get(
                "message"
            )

            sender_node = packet.get(
                "source_node"
            )

            if not message_id or message is None:
                return

            self.db.execute(
                """
                UPDATE server_group_messages
                SET message=?,
                    group_key_id=COALESCE(?, group_key_id)
                WHERE message_id=?
                AND sender_node=?
                """,
                (
                    message,
                    packet.get("group_key_id"),
                    message_id,
                    sender_node
                )
            )

            self.db.execute(
                """
                UPDATE server_files
                SET caption=?,
                    group_key_id=COALESCE(?, group_key_id)
                WHERE file_id=?
                AND sender_node=?
                """,
                (
                    message,
                    packet.get("group_key_id"),
                    message_id,
                    sender_node
                )
            )

            self.db.commit()

        elif packet_type == "group_message_delete":

            message_id = packet.get(
                "group_message_id"
            )

            sender_node = packet.get(
                "source_node"
            )

            if not message_id:
                return

            self.db.execute(
                """
                DELETE FROM server_group_messages
                WHERE message_id=?
                AND sender_node=?
                """,
                (
                    message_id,
                    sender_node
                )
            )

            self.db.execute(
                """
                DELETE FROM server_reactions
                WHERE message_id=?
                """,
                (
                    message_id,
                )
            )

            self.db.execute(
                """
                DELETE FROM server_files
                WHERE file_id=?
                AND sender_node=?
                """,
                (
                    message_id,
                    sender_node
                )
            )

            self.db.execute(
                """
                DELETE FROM server_pins
                WHERE message_id=?
                """,
                (
                    message_id,
                )
            )

            self.db.commit()

        elif packet_type in ("message_reaction", "group_reaction"):

            scope = (
                f"group:{packet.get('group_id')}"
                if packet_type == "group_reaction"
                else "direct"
            )

            message_id = (
                packet.get("group_message_id")
                or packet.get("message_id")
            )

            reactor_node = packet.get("source_node")
            reaction = packet.get("reaction")

            if not message_id or not reactor_node or not reaction:
                return

            cursor = self.db.execute(
                """
                INSERT OR IGNORE INTO server_reactions(
                    scope,
                    message_id,
                    reactor_node,
                    reactor_login,
                    reaction
                )
                VALUES(?,?,?,?,?)
                """,
                (
                    scope,
                    message_id,
                    reactor_node,
                    self.get_login_by_node(reactor_node),
                    reaction
                )
            )

            self.db.commit()
            return cursor.rowcount > 0

        elif packet_type == "file_chunk":

            file_id = packet.get("file_id")
            filename = packet.get("filename")
            chunk_index = packet.get("chunk_index")
            total_chunks = packet.get("total_chunks")
            data = packet.get("data")

            if (
                not file_id
                or not filename
                or chunk_index is None
                or not total_chunks
                or data is None
            ):
                return

            if file_id not in self.file_chunks:

                self.file_chunks[
                    file_id
                ] = {
                    "packet": packet,
                    "total_chunks": total_chunks,
                    "chunks": {}
                }

            self.file_chunks[
                file_id
            ][
                "chunks"
            ][
                chunk_index
            ] = data

            info = self.file_chunks[
                file_id
            ]

            if len(info["chunks"]) != info["total_chunks"]:
                return

            full_data = "".join(
                info["chunks"][i]
                for i in range(
                    info["total_chunks"]
                )
            )

            first_packet = info["packet"]
            sender_node = first_packet.get("source_node")
            receiver_node = first_packet.get("destination_node")

            self.db.execute(
                """
                INSERT OR IGNORE INTO server_files(
                    file_id,
                    sender_node,
                    sender_login,
                    sender_name,
                    receiver_node,
                    receiver_login,
                    group_id,
                    filename,
                    caption,
                    data,
                    group_key_id,
                    chat_kind,
                    chat_id,
                    created_at
                )
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,STRFTIME(
                    '%Y-%m-%d %H:%M:%f',
                    'now'
                ))
                """,
                (
                    file_id,
                    sender_node,
                    self.get_login_by_node(sender_node),
                    first_packet.get("sender") or sender_node,
                    receiver_node,
                    self.get_login_by_node(receiver_node),
                    first_packet.get("group_id"),
                    filename,
                    first_packet.get("caption") or "",
                    full_data,
                    first_packet.get("group_key_id"),
                    first_packet.get("chat_kind") or "normal",
                    first_packet.get("chat_id") or ""
                )
            )

            self.db.commit()

            del self.file_chunks[
                file_id
            ]

    def save_group_key_envelopes(
        self,
        packet
    ):

        group_id = packet.get("group_id")
        key_id = packet.get("group_key_id")

        if not group_id or not key_id:
            return

        if (
            packet.get("type") == "file_chunk"
            and packet.get("chunk_index") != 0
        ):
            return

        for member_node, envelope in (
            (
                packet.get("destination_node"),
                packet.get("group_key_envelope")
            ),
            (
                packet.get("source_node"),
                packet.get("group_key_sender_envelope")
            )
        ):

            if not member_node or not envelope:
                continue

            self.db.execute(
                """
                INSERT INTO server_group_keys(
                    group_id,
                    key_id,
                    member_node,
                    member_login,
                    key_envelope
                )
                VALUES(?,?,?,?,?)
                ON CONFLICT(group_id, key_id, member_node)
                DO UPDATE SET
                    member_login=excluded.member_login,
                    key_envelope=excluded.key_envelope
                """,
                (
                    group_id,
                    key_id,
                    member_node,
                    self.get_login_by_node(member_node),
                    envelope
                )
            )

        self.db.commit()

    def save_offline_packet(
        self,
        destination_node,
        packet
    ):

        self.db.execute(
            """
            INSERT INTO offline_packets(
                destination_node,
                packet_json
            )
            VALUES(?,?)
            """,
            (
                destination_node,
                json.dumps(
                    packet,
                    ensure_ascii=False
                )
            )
        )

        self.db.commit()

    async def flush_offline_packets(
        self,
        node_id,
        websocket
    ):

        cursor = self.db.cursor()

        cursor.execute(
            """
            SELECT id,
                   packet_json

            FROM offline_packets

            WHERE destination_node=?

            ORDER BY id
            """,
            (
                node_id,
            )
        )

        rows = cursor.fetchall()

        for packet_id, packet_json in rows:

            await websocket.send(
                packet_json
            )

            self.db.execute(
                """
                DELETE FROM offline_packets

                WHERE id=?
                """,
                (
                    packet_id,
                )
            )

        self.db.commit()
