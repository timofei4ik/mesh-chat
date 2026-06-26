import sqlite3
import os
import sys
import hashlib
from pathlib import Path

from storage.database_messages import DatabaseMessagesMixin
from storage.database_pending import DatabasePendingMixin
from storage.database_groups import DatabaseGroupsMixin
from storage.database_contacts import DatabaseContactsMixin
from storage.database_settings import DatabaseSettingsMixin
from storage.database_files import DatabaseFilesMixin


def get_database_dir():

    if getattr(
        sys,
        "frozen",
        False
    ):

        base_dir = os.environ.get(
            "APPDATA"
        )

        if not base_dir:

            base_dir = str(
                Path.home()
            )

        data_dir = Path(
            base_dir
        ) / "MeshChat"

        data_dir.mkdir(
            parents=True,
            exist_ok=True
        )

        return data_dir

    return Path(".")


def get_database_path():

    override_path = os.environ.get(
        "MESHCHAT_DB_PATH"
    )

    if override_path:

        return override_path

    return str(
        get_database_dir() / "messages.db"
    )


def get_account_database_path(
    login
):

    raw_login = (
        login
        or ""
    ).strip()

    login = raw_login.lower()

    if not login:

        return get_database_path()

    safe_login = "".join(
        char
        if (
            char.isalnum()
            or char in (
                "-",
                "_",
                "."
            )
        )
        else "_"
        for char in login
    ).strip(
        "._ "
    )

    digest = hashlib.sha256(
        login.encode(
            "utf-8"
        )
    ).hexdigest()[:16]

    if not safe_login:

        safe_login = digest

    account_dir = (
        get_database_dir()
        / "accounts"
        / safe_login
    )

    account_dir.mkdir(
        parents=True,
        exist_ok=True
    )

    new_path = account_dir / "messages.db"
    old_path = get_database_dir() / f"messages_account_{digest}.db"

    if (
        old_path.exists()
        and not new_path.exists()
    ):

        old_path.replace(
            new_path
        )

    return str(
        new_path
    )


def list_account_profiles():

    accounts_dir = get_database_dir() / "accounts"

    if not accounts_dir.exists():

        return []

    profiles = []

    for account_dir in sorted(
        accounts_dir.iterdir()
    ):

        db_path = account_dir / "messages.db"

        if (
            account_dir.is_dir()
            and db_path.exists()
        ):

            profiles.append(
                {
                    "login": account_dir.name,
                    "path": str(
                        db_path
                    )
                }
            )

    return profiles


class Database(
    DatabaseMessagesMixin,
    DatabasePendingMixin,
    DatabaseGroupsMixin,
    DatabaseContactsMixin,
    DatabaseSettingsMixin,
    DatabaseFilesMixin
):

    def __init__(
        self,
        path=None
    ):

        self.path = path or get_database_path()

        self.conn = sqlite3.connect(
            self.path,
            check_same_thread=False
        )

        self.create_tables()

    def create_tables(self):

        cursor = self.conn.cursor()

        cursor.execute("""
        CREATE TABLE IF NOT EXISTS messages(

            id INTEGER PRIMARY KEY AUTOINCREMENT,

            message_id TEXT,

            sender TEXT,

            receiver TEXT,

            message TEXT,

            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
        )
        """)

        cursor.execute("""
        CREATE TABLE IF NOT EXISTS unread(

            sender TEXT,

            receiver TEXT,

            count INTEGER,

            PRIMARY KEY(
                sender,
                receiver
            )
        )
        """)

        cursor.execute("""
        CREATE TABLE IF NOT EXISTS settings(

            key TEXT PRIMARY KEY,

            value TEXT
        )
        """)

        cursor.execute("""
        CREATE TABLE IF NOT EXISTS users(

            node_id TEXT PRIMARY KEY,

            name TEXT,

            ip TEXT,

            port INTEGER,

            avatar_path TEXT,

            public_username TEXT,

            about TEXT,

            encryption_public_key TEXT,

            last_seen DATETIME DEFAULT CURRENT_TIMESTAMP
        )
        """)

        self.conn.commit()

        cursor.execute("""
        CREATE TABLE IF NOT EXISTS contact_status(

            node_id TEXT PRIMARY KEY,

            status TEXT NOT NULL,

            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
        """)

        self.conn.commit()

        cursor.execute(
            "PRAGMA table_info(users)"
        )

        user_columns = {
            row[1]
            for row in cursor.fetchall()
        }

        if "avatar_path" not in user_columns:

            cursor.execute(
                "ALTER TABLE users ADD COLUMN avatar_path TEXT"
            )

            self.conn.commit()

        if "about" not in user_columns:

            cursor.execute(
                "ALTER TABLE users ADD COLUMN about TEXT"
            )

            self.conn.commit()

        if "public_username" not in user_columns:

            cursor.execute(
                "ALTER TABLE users ADD COLUMN public_username TEXT"
            )

            self.conn.commit()

        if "encryption_public_key" not in user_columns:

            cursor.execute(
                "ALTER TABLE users ADD COLUMN encryption_public_key TEXT"
            )

            self.conn.commit()


        cursor.execute("""
                CREATE TABLE IF NOT EXISTS files(

                    id INTEGER PRIMARY KEY AUTOINCREMENT,

                    sender_node TEXT,

                    receiver_node TEXT,

                    filename TEXT,

                    data TEXT,

                    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
                )
        """)

        self.conn.commit()

        cursor.execute(
            "PRAGMA table_info(messages)"
        )

        message_columns = {
            row[1]
            for row in cursor.fetchall()
        }

        if "message_id" not in message_columns:

            cursor.execute(
                "ALTER TABLE messages ADD COLUMN message_id TEXT"
            )

            self.conn.commit()

        cursor.execute(
            "PRAGMA table_info(files)"
        )

        file_columns = {
            row[1]
            for row in cursor.fetchall()
        }

        if "file_id" not in file_columns:

            cursor.execute(
                "ALTER TABLE files ADD COLUMN file_id TEXT"
            )

            self.conn.commit()

        cursor.execute(
            """
            DELETE FROM files
            WHERE file_id IS NOT NULL
            AND id NOT IN (
                SELECT MIN(id)
                FROM files
                WHERE file_id IS NOT NULL
                GROUP BY file_id
            )
            """
        )

        cursor.execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_files_file_id
            ON files(file_id)
            WHERE file_id IS NOT NULL
            """
        )

        cursor.execute(
            """
            DELETE FROM messages
            WHERE message_id IS NOT NULL
            AND id NOT IN (
                SELECT MIN(id)
                FROM messages
                WHERE message_id IS NOT NULL
                GROUP BY message_id
            )
            """
        )

        cursor.execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_message_id
            ON messages(message_id)
            WHERE message_id IS NOT NULL
            """
        )

        cursor.execute("""
        CREATE TABLE IF NOT EXISTS pending_messages(

            message_id TEXT PRIMARY KEY,

            sender_node TEXT,

            receiver_node TEXT,

            message TEXT,

            attempts INTEGER DEFAULT 0,

            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,

            last_attempt DATETIME
        )
        """)

        self.conn.commit()

        cursor.execute(
            "PRAGMA table_info(pending_messages)"
        )

        pending_columns = {
            row[1]
            for row in cursor.fetchall()
        }

        if "packet_json" not in pending_columns:

            cursor.execute(
                "ALTER TABLE pending_messages ADD COLUMN packet_json TEXT"
            )

            self.conn.commit()

        cursor.execute("""
        CREATE TABLE IF NOT EXISTS groups(

            group_id TEXT PRIMARY KEY,

            name TEXT,

            owner_node TEXT,

            admins_json TEXT DEFAULT '[]'
        )
        """)

        cursor.execute(
            "PRAGMA table_info(groups)"
        )

        group_columns = {
            row[1]
            for row in cursor.fetchall()
        }

        if "owner_node" not in group_columns:

            cursor.execute(
                "ALTER TABLE groups ADD COLUMN owner_node TEXT"
            )

        if "admins_json" not in group_columns:

            cursor.execute(
                "ALTER TABLE groups ADD COLUMN admins_json TEXT DEFAULT '[]'"
            )

        cursor.execute("""
        CREATE TABLE IF NOT EXISTS group_members(

            group_id TEXT,

            node_id TEXT,

            PRIMARY KEY(
                group_id,
                node_id
            )
        )
        """)

        cursor.execute("""
        CREATE TABLE IF NOT EXISTS group_encryption_keys(

            group_id TEXT,

            key_id TEXT,

            key_envelope TEXT NOT NULL,

            active INTEGER DEFAULT 0,

            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,

            PRIMARY KEY(
                group_id,
                key_id
            )
        )
        """)

        cursor.execute("""
        CREATE TABLE IF NOT EXISTS group_messages(

            id INTEGER PRIMARY KEY AUTOINCREMENT,

            group_id TEXT,

            message_id TEXT,

            sender_node TEXT,

            sender_name TEXT,

            message TEXT,

            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
        )
        """)

        cursor.execute(
            """
            DELETE FROM group_messages
            WHERE message_id IS NOT NULL
            AND id NOT IN (
                SELECT MIN(id)
                FROM group_messages
                WHERE message_id IS NOT NULL
                GROUP BY message_id
            )
            """
        )

        cursor.execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_group_messages_message_id
            ON group_messages(message_id)
            WHERE message_id IS NOT NULL
            """
        )

        self.conn.commit()

        cursor.execute("""
        CREATE TABLE IF NOT EXISTS message_reactions(

            scope TEXT,

            message_id TEXT,

            reactor_node TEXT,

            reaction TEXT,

            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,

            PRIMARY KEY(
                scope,
                message_id,
                reactor_node,
                reaction
            )
        )
        """)

        cursor.execute("""
        CREATE TABLE IF NOT EXISTS message_pins(

            scope TEXT,

            message_id TEXT,

            text TEXT,

            pinner_node TEXT,

            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,

            PRIMARY KEY(
                scope,
                message_id
            )
        )
        """)

        self.conn.commit()



    def get_contacts(
            self,
            username
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            SELECT DISTINCT receiver

            FROM messages

            WHERE sender=?

            UNION SELECT DISTINCT sender

            FROM messages

            WHERE receiver=?
            """,

            (
                username,
                username
            )
        )

        contacts = [
            row[0]
            for row in cursor.fetchall()
            if not self.is_contact_blocked(row[0])
        ]

        cursor.execute(
            """
            SELECT node_id
            FROM contact_status
            WHERE status IN ('friend', 'outgoing', 'incoming', 'blocked')
            """
        )

        contacts.extend(
            row[0]
            for row in cursor.fetchall()
        )

        return list(
            dict.fromkeys(
                contacts
            )
        )
