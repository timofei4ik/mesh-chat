import sqlite3
import uuid
import traceback


class Database:

    def __init__(self):

        self.conn = sqlite3.connect(
            "messages.db",
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

            last_seen DATETIME DEFAULT CURRENT_TIMESTAMP
        )
        """)

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


    def save_message(
        self,
        sender,
        receiver,
        message,
        message_id=None
    ):
        
        print(
            "SAVE:",
            sender,
            receiver,
            message
        )

        cursor = self.conn.cursor()

        cursor.execute(
            """
            INSERT INTO messages(
                message_id,
                sender,
                receiver,
                message
            )
            VALUES(?,?,?,?)
            """,
            (
                message_id,
                sender,
                receiver,
                message
            )
        )

        self.conn.commit()

    def add_pending_message(
        self,
        message_id,
        sender_node,
        receiver_node,
        message
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            INSERT OR IGNORE INTO pending_messages(
                message_id,
                sender_node,
                receiver_node,
                message
            )
            VALUES(?,?,?,?)
            """,
            (
                message_id,
                sender_node,
                receiver_node,
                message
            )
        )

        self.conn.commit()

    def get_pending_messages(
        self,
        sender_node
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            SELECT
                message_id,
                receiver_node,
                message,
                attempts

            FROM pending_messages

            WHERE sender_node=?

            ORDER BY created_at
            """,
            (
                sender_node,
            )
        )

        return cursor.fetchall()

    def get_pending_message_ids(
        self,
        sender_node,
        receiver_node
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            SELECT message_id

            FROM pending_messages

            WHERE sender_node=?
            AND receiver_node=?
            """,
            (
                sender_node,
                receiver_node
            )
        )

        return {
            row[0]
            for row in cursor.fetchall()
        }

    def mark_pending_attempt(
        self,
        message_id
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            UPDATE pending_messages

            SET attempts=attempts+1,
                last_attempt=CURRENT_TIMESTAMP

            WHERE message_id=?
            """,
            (
                message_id,
            )
        )

        self.conn.commit()

    def remove_pending_message(
        self,
        message_id
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            DELETE FROM pending_messages

            WHERE message_id=?
            """,
            (
                message_id,
            )
        )

        self.conn.commit()

    def get_messages(
        self,
        user1,
        user2
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            SELECT sender,
                   receiver,
                   message,
                   timestamp

            FROM messages

            WHERE

            (
                sender=? AND receiver=?
            )

            OR

            (
                sender=? AND receiver=?
            )

            ORDER BY id
            """,
            (
                user1,
                user2,
                user2,
                user1
            )
        )

        return cursor.fetchall()
    
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

        return [
            row[0]
            for row in cursor.fetchall()
        ]
    
    def add_unread(
    self,
    sender,
    receiver
):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            INSERT INTO unread(
                sender,
                receiver,
                count
            )

            VALUES(?,?,1)

            ON CONFLICT(sender,receiver)

            DO UPDATE SET

            count=count+1
            """,
            (
                sender,
                receiver
            )
        )

        self.conn.commit()

    def get_unread(
    self,
    sender,
    receiver
):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            SELECT count

            FROM unread

            WHERE sender=?
            AND receiver=?
            """,
            (
                sender,
                receiver
            )
        )

        row = cursor.fetchone()

        if row:

            return row[0]

        return 0
    
    def clear_unread(
    self,
    sender,
    receiver
):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            DELETE FROM unread

            WHERE sender=?
            AND receiver=?
            """,
            (
                sender,
                receiver
            )
        )

        self.conn.commit()

    def get_setting(
    self,
    key,
    default=None
):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            SELECT value

            FROM settings

            WHERE key=?
            """,
            (key,)
        )

        row = cursor.fetchone()

        if row:
            return row[0]

        return default
    
    def set_setting(
    self,
    key,
    value
):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            INSERT OR REPLACE
            INTO settings(
                key,
                value
            )

            VALUES(?,?)
            """,
            (
                key,
                value
            )
        )

        self.conn.commit()

    def get_or_create_node_id(
    self,
    port
    ):

        key = f"node_id_{port}"

        node_id = self.get_setting(
            key
        )

        if node_id:
            return node_id

        node_id = str(
            uuid.uuid4()
        )

        self.set_setting(
            key,
            node_id
        )

        return node_id
    
    def update_user(
    self,
    node_id,
    name,
    ip,
    port
):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            INSERT OR REPLACE INTO users(

                node_id,
                name,
                ip,
                port,
                last_seen

            )

            VALUES(
                ?,?,?,?,
                CURRENT_TIMESTAMP
            )
            """,
            (
                node_id,
                name,
                ip,
                port
            )
        )

        self.conn.commit()

    def get_user_name(
    self,
    node_id
):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            SELECT name

            FROM users

            WHERE node_id=?
            """,
            (
                node_id,
            )
        )

        row = cursor.fetchone()

        if row:
            return row[0]

        return node_id[:8]
    
    def get_user_info(
    self,
    node_id
):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            SELECT
                name,
                ip,
                port

            FROM users

            WHERE node_id=?
            """,
            (
                node_id,
            )
        )

        return cursor.fetchone()

    def get_bluetooth_contacts(self):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            SELECT node_id

            FROM users

            WHERE ip LIKE 'BT:%'
            """
        )

        return [
            row[0]
            for row in cursor.fetchall()
        ]
    
    def save_file(
    self,
    sender_node,
    receiver_node,
    filename,
    data
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            INSERT INTO files(
                sender_node,
                receiver_node,
                filename,
                data
            )
            VALUES(?,?,?,?)
            """,
            (
                sender_node,
                receiver_node,
                filename,
                data
            )
        )

        self.conn.commit()

    def get_files(
        self,
        node1,
        node2
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            SELECT filename,
                data,
                sender_node
            FROM files

            WHERE

            (
                sender_node=? AND receiver_node=?
            )

            OR

            (
                sender_node=? AND receiver_node=?
            )

            ORDER BY id
            """,
            (
                node1,
                node2,
                node2,
                node1
            )
        )

        return cursor.fetchall()
    
    def get_chat_history(
        self,
        node1,
        node2
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            SELECT
                'message' as item_type,
                message_id,
                sender,
                receiver,
                message as content,
                timestamp

            FROM messages

            WHERE

            (
                sender=? AND receiver=?
            )

            OR

            (
                sender=? AND receiver=?
            )

            UNION ALL

            SELECT
                'file' as item_type,
                NULL as message_id,
                sender_node,
                receiver_node,
                filename as content,
                timestamp

            FROM files

            WHERE

            (
                sender_node=? AND receiver_node=?
            )

            OR

            (
                sender_node=? AND receiver_node=?
            )

            ORDER BY timestamp
            """,
            (
                node1,
                node2,
                node2,
                node1,

                node1,
                node2,
                node2,
                node1
            )
        )

        return cursor.fetchall()
