import uuid


class DatabaseContactsMixin:
    def delete_contact(
        self,
        node_id
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            DELETE FROM users
            WHERE node_id=?
            """,
            (
                node_id,
            )
        )

        cursor.execute(
            """
            DELETE FROM contact_status
            WHERE node_id=?
            """,
            (
                node_id,
            )
        )

        self.conn.commit()

    def set_contact_status(
        self,
        node_id,
        status
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            INSERT INTO contact_status(node_id, status, updated_at)
            VALUES(?,?,CURRENT_TIMESTAMP)
            ON CONFLICT(node_id) DO UPDATE SET
                status=excluded.status,
                updated_at=CURRENT_TIMESTAMP
            """,
            (
                node_id,
                status
            )
        )

        self.conn.commit()

    def get_contact_status(
        self,
        node_id
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            SELECT status
            FROM contact_status
            WHERE node_id=?
            """,
            (
                node_id,
            )
        )

        row = cursor.fetchone()
        return row[0] if row else ""

    def clear_contact_status(
        self,
        node_id
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            DELETE FROM contact_status
            WHERE node_id=?
            """,
            (
                node_id,
            )
        )

        self.conn.commit()

    def is_contact_blocked(
        self,
        node_id
    ):

        return self.get_contact_status(
            node_id
        ) == "blocked"

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
            INSERT INTO users(
                node_id,
                name,
                ip,
                port,
                last_seen
            )
            VALUES(?,?,?,?,CURRENT_TIMESTAMP)
            ON CONFLICT(node_id) DO UPDATE SET
                name=excluded.name,
                ip=excluded.ip,
                port=excluded.port,
                last_seen=CURRENT_TIMESTAMP
            """,
            (
                node_id,
                name,
                ip,
                port
            )
        )

        self.conn.commit()

    def update_user_profile(
        self,
        node_id,
        avatar_path=None,
        about=None,
        public_username=None,
        encryption_public_key=None
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            INSERT INTO users(
                node_id,
                name,
                ip,
                port,
                avatar_path,
                public_username,
                about,
                encryption_public_key,
                last_seen
            )
            VALUES(?,?,?,?,?,?,?,?,CURRENT_TIMESTAMP)
            ON CONFLICT(node_id) DO UPDATE SET
                avatar_path=COALESCE(excluded.avatar_path, users.avatar_path),
                public_username=COALESCE(excluded.public_username, users.public_username),
                about=COALESCE(excluded.about, users.about),
                encryption_public_key=CASE
                    WHEN users.encryption_public_key IS NULL
                      OR users.encryption_public_key = ''
                    THEN excluded.encryption_public_key
                    ELSE users.encryption_public_key
                END
            """,
            (
                node_id,
                node_id[:8],
                "",
                0,
                avatar_path,
                public_username,
                about,
                encryption_public_key
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
            SELECT name,
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

    def get_user_profile(
        self,
        node_id
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            SELECT name,
                   ip,
                   port,
                   avatar_path,
                   public_username,
                   about,
                   encryption_public_key
            FROM users
            WHERE node_id=?
            """,
            (
                node_id,
            )
        )

        return cursor.fetchone()

    def get_user_encryption_key(
        self,
        node_id
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            SELECT encryption_public_key
            FROM users
            WHERE node_id=?
            """,
            (
                node_id,
            )
        )

        row = cursor.fetchone()

        return row[0] if row else ""

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
