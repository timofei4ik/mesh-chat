import json


class DatabaseGroupsMixin:
    def save_group(
        self,
        group_id,
        name,
        members,
        owner_node=None,
        admins=None
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            INSERT INTO groups(
                group_id,
                name,
                owner_node,
                admins_json
            )
            VALUES(?,?,?,?)
            ON CONFLICT(group_id) DO UPDATE SET
                name=excluded.name,
                owner_node=COALESCE(excluded.owner_node, groups.owner_node),
                admins_json=CASE
                    WHEN ? THEN excluded.admins_json
                    ELSE groups.admins_json
                END
            """,
            (
                group_id,
                name,
                owner_node,
                json.dumps(
                    admins or [],
                    ensure_ascii=False
                ),
                admins is not None
            )
        )

        for member in members:

            cursor.execute(
                """
                INSERT OR IGNORE INTO group_members(
                    group_id,
                    node_id
                )
                VALUES(?,?)
                """,
                (
                    group_id,
                    member
                )
            )

        self.conn.commit()

    def get_groups(self):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            SELECT group_id,
                   name

            FROM groups

            ORDER BY name
            """
        )

        return cursor.fetchall()

    def get_group_members(
        self,
        group_id
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            SELECT node_id

            FROM group_members

            WHERE group_id=?

            ORDER BY node_id
            """,
            (
                group_id,
            )
        )

        return [
            row[0]
            for row in cursor.fetchall()
        ]

    def rename_group(
        self,
        group_id,
        name
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            UPDATE groups

            SET name=?

            WHERE group_id=?
            """,
            (
                name,
                group_id
            )
        )

        self.conn.commit()

    def set_group_members(
        self,
        group_id,
        members
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            DELETE FROM group_members

            WHERE group_id=?
            """,
            (
                group_id,
            )
        )

        for member in members:

            cursor.execute(
                """
                INSERT OR IGNORE INTO group_members(
                    group_id,
                    node_id
                )
                VALUES(?,?)
                """,
                (
                    group_id,
                    member
                )
            )

        self.conn.commit()

    def delete_group(
        self,
        group_id
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            DELETE FROM group_messages

            WHERE group_id=?
            """,
            (
                group_id,
            )
        )

        cursor.execute(
            """
            DELETE FROM group_members

            WHERE group_id=?
            """,
            (
                group_id,
            )
        )

        cursor.execute(
            """
            DELETE FROM groups

            WHERE group_id=?
            """,
            (
                group_id,
            )
        )

        cursor.execute(
            """
            DELETE FROM group_encryption_keys
            WHERE group_id=?
            """,
            (
                group_id,
            )
        )

        self.conn.commit()

    def save_group_message(
        self,
        group_id,
        message_id,
        sender_node,
        sender_name,
        message,
        timestamp=None
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            INSERT OR IGNORE INTO group_messages(
                group_id,
                message_id,
                sender_node,
                sender_name,
                message,
                timestamp
            )
            VALUES(?,?,?,?,?,COALESCE(
                ?,
                STRFTIME('%Y-%m-%d %H:%M:%f', 'now')
            ))
            """,
            (
                group_id,
                message_id,
                sender_node,
                sender_name,
                message,
                timestamp
            )
        )

        self.conn.commit()

    def get_group_roles(
        self,
        group_id
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            SELECT owner_node,
                   admins_json
            FROM groups
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

        try:
            admins = json.loads(
                row[1] or "[]"
            )
        except (TypeError, ValueError):
            admins = []

        members = self.get_group_members(
            group_id
        )

        if not owner_node and members:

            owner_node = sorted(
                members
            )[0]

            self.set_group_roles(
                group_id,
                owner_node,
                admins
            )

        admins = [
            node_id
            for node_id in dict.fromkeys(
                admins
            )
            if node_id in members
            and node_id != owner_node
        ]

        return owner_node, admins

    def set_group_roles(
        self,
        group_id,
        owner_node,
        admins
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            UPDATE groups
            SET owner_node=?,
                admins_json=?
            WHERE group_id=?
            """,
            (
                owner_node or "",
                json.dumps(
                    admins or [],
                    ensure_ascii=False
                ),
                group_id
            )
        )

        self.conn.commit()

    def can_manage_group(
        self,
        group_id,
        node_id
    ):

        owner_node, admins = self.get_group_roles(
            group_id
        )

        return (
            node_id == owner_node
            or node_id in admins
        )

    def save_group_encryption_key(
        self,
        group_id,
        key_id,
        key_envelope,
        active=True
    ):

        cursor = self.conn.cursor()

        if active:

            cursor.execute(
                """
                UPDATE group_encryption_keys
                SET active=0
                WHERE group_id=?
                """,
                (
                    group_id,
                )
            )

        cursor.execute(
            """
            INSERT INTO group_encryption_keys(
                group_id,
                key_id,
                key_envelope,
                active
            )
            VALUES(?,?,?,?)
            ON CONFLICT(group_id, key_id) DO UPDATE SET
                key_envelope=excluded.key_envelope,
                active=MAX(
                    group_encryption_keys.active,
                    excluded.active
                )
            """,
            (
                group_id,
                key_id,
                key_envelope,
                1 if active else 0
            )
        )

        self.conn.commit()

    def get_group_encryption_key(
        self,
        group_id,
        key_id=None
    ):

        cursor = self.conn.cursor()

        if key_id:

            cursor.execute(
                """
                SELECT key_id,
                       key_envelope
                FROM group_encryption_keys
                WHERE group_id=?
                  AND key_id=?
                """,
                (
                    group_id,
                    key_id
                )
            )

        else:

            cursor.execute(
                """
                SELECT key_id,
                       key_envelope
                FROM group_encryption_keys
                WHERE group_id=?
                ORDER BY active DESC,
                         created_at DESC
                LIMIT 1
                """,
                (
                    group_id,
                )
            )

        return cursor.fetchone()

    def update_group_message(
        self,
        message_id,
        message
    ):

        if not message_id:
            return

        cursor = self.conn.cursor()

        cursor.execute(
            """
            UPDATE group_messages
            SET message=?
            WHERE message_id=?
            """,
            (
                message,
                message_id
            )
        )

        self.conn.commit()

    def delete_group_message(
        self,
        message_id
    ):

        if not message_id:
            return

        cursor = self.conn.cursor()

        cursor.execute(
            """
            DELETE FROM group_messages
            WHERE message_id=?
            """,
            (
                message_id,
            )
        )

        cursor.execute(
            """
            DELETE FROM message_reactions
            WHERE message_id=?
            """,
            (
                message_id,
            )
        )

        cursor.execute(
            """
            DELETE FROM message_pins
            WHERE message_id=?
            """,
            (
                message_id,
            )
        )

        self.conn.commit()

    def get_group_history(
        self,
        group_id
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            SELECT
                message_id,
                sender_node,
                sender_name,
                message,
                timestamp

            FROM group_messages

            WHERE group_id=?

            ORDER BY id
            """,
            (
                group_id,
            )
        )

        return cursor.fetchall()

    def get_group_last_activity(
        self,
        group_id
    ):

        cursor = self.conn.cursor()
        cursor.execute(
            """
            SELECT item_type, content, timestamp
            FROM (
                SELECT 'message' AS item_type,
                       message AS content,
                       timestamp
                FROM group_messages
                WHERE group_id=?

                UNION ALL

                SELECT 'file' AS item_type,
                       filename AS content,
                       timestamp
                FROM files
                WHERE receiver_node=?
            )
            ORDER BY timestamp DESC
            LIMIT 1
            """,
            (
                group_id,
                f"group:{group_id}"
            )
        )

        return cursor.fetchone()
