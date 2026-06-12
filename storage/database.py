import sqlite3
import uuid


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

    def save_message(
        self,
        sender,
        receiver,
        message
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            INSERT INTO messages(
                sender,
                receiver,
                message
            )
            VALUES(?,?,?)
            """,
            (
                sender,
                receiver,
                message
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