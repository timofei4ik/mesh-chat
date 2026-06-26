class DatabaseMessagesMixin:
    def save_message(
        self,
        sender,
        receiver,
        message,
        message_id=None,
        timestamp=None
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            INSERT OR IGNORE INTO messages(
                message_id,
                sender,
                receiver,
                message,
                timestamp
            )
            VALUES(?,?,?,?,COALESCE(
                ?,
                STRFTIME('%Y-%m-%d %H:%M:%f', 'now')
            ))
            """,
            (
                message_id,
                sender,
                receiver,
                message,
                timestamp
            )
        )

        self.conn.commit()

    def update_message(
        self,
        message_id,
        message
    ):

        if not message_id:
            return

        cursor = self.conn.cursor()

        cursor.execute(
            """
            UPDATE messages
            SET message=?
            WHERE message_id=?
            """,
            (
                message,
                message_id
            )
        )

        self.conn.commit()

    def delete_message(
        self,
        message_id
    ):

        if not message_id:
            return

        cursor = self.conn.cursor()

        cursor.execute(
            """
            DELETE FROM messages
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
            DELETE FROM pending_messages
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

    def save_reaction(
        self,
        scope,
        message_id,
        reactor_node,
        reaction
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            INSERT OR IGNORE INTO message_reactions(
                scope,
                message_id,
                reactor_node,
                reaction
            )
            VALUES(?,?,?,?)
            """,
            (
                scope,
                message_id,
                reactor_node,
                reaction
            )
        )

        self.conn.commit()

    def get_reactions(
        self,
        scope,
        message_id
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            SELECT reactor_node,
                   reaction

            FROM message_reactions

            WHERE scope=?
            AND message_id=?
            """,
            (
                scope,
                message_id
            )
        )

        return cursor.fetchall()

    def clear_chat(
        self,
        node1,
        node2
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            DELETE FROM messages

            WHERE

            (
                sender=? AND receiver=?
            )

            OR

            (
                sender=? AND receiver=?
            )
            """,
            (
                node1,
                node2,
                node2,
                node1
            )
        )

        cursor.execute(
            """
            DELETE FROM files

            WHERE

            (
                sender_node=? AND receiver_node=?
            )

            OR

            (
                sender_node=? AND receiver_node=?
            )
            """,
            (
                node1,
                node2,
                node2,
                node1
            )
        )

        cursor.execute(
            """
            DELETE FROM unread

            WHERE

            (
                sender=? AND receiver=?
            )

            OR

            (
                sender=? AND receiver=?
            )
            """,
            (
                node1,
                node2,
                node2,
                node1
            )
        )

        cursor.execute(
            """
            DELETE FROM pending_messages

            WHERE

            (
                sender_node=? AND receiver_node=?
            )

            OR

            (
                sender_node=? AND receiver_node=?
            )
            """,
            (
                node1,
                node2,
                node2,
                node1
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

    def save_pin(
        self,
        scope,
        message_id,
        text,
        pinner_node
    ):

        if not scope or not message_id:
            return

        self.conn.execute(
            """
            INSERT INTO message_pins(
                scope,
                message_id,
                text,
                pinner_node,
                created_at
            )
            VALUES(?,?,?,?,CURRENT_TIMESTAMP)
            ON CONFLICT(scope, message_id) DO UPDATE SET
                text=excluded.text,
                pinner_node=excluded.pinner_node,
                created_at=CURRENT_TIMESTAMP
            """,
            (
                scope,
                message_id,
                text or "",
                pinner_node or ""
            )
        )

        self.conn.commit()

    def remove_pin(
        self,
        scope,
        message_id
    ):

        self.conn.execute(
            """
            DELETE FROM message_pins
            WHERE scope=?
              AND message_id=?
            """,
            (
                scope,
                message_id
            )
        )

        self.conn.commit()

    def get_pins(
        self,
        scope
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            SELECT message_id,
                   text,
                   pinner_node,
                   created_at
            FROM message_pins
            WHERE scope=?
            ORDER BY created_at DESC,
                     rowid DESC
            """,
            (
                scope,
            )
        )

        return cursor.fetchall()

    def clear_pins(
        self,
        scope
    ):

        self.conn.execute(
            """
            DELETE FROM message_pins
            WHERE scope=?
            """,
            (
                scope,
            )
        )

        self.conn.commit()

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

    def get_chat_last_activity(
        self,
        node1,
        node2
    ):

        cursor = self.conn.cursor()
        cursor.execute(
            """
            SELECT item_type, content, timestamp
            FROM (
                SELECT 'message' AS item_type,
                       message AS content,
                       timestamp
                FROM messages
                WHERE (sender=? AND receiver=?)
                   OR (sender=? AND receiver=?)

                UNION ALL

                SELECT 'file' AS item_type,
                       filename AS content,
                       timestamp
                FROM files
                WHERE (sender_node=? AND receiver_node=?)
                   OR (sender_node=? AND receiver_node=?)
            )
            ORDER BY timestamp DESC
            LIMIT 1
            """,
            (
                node1, node2,
                node2, node1,
                node1, node2,
                node2, node1
            )
        )

        return cursor.fetchone()
