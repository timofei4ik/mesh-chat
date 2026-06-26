import json


class DatabasePendingMixin:
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

    def add_pending_packet(
        self,
        message_id,
        sender_node,
        receiver_node,
        message,
        packet
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            INSERT OR IGNORE INTO pending_messages(
                message_id,
                sender_node,
                receiver_node,
                message,
                packet_json
            )
            VALUES(?,?,?,?,?)
            """,
            (
                message_id,
                sender_node,
                receiver_node,
                message,
                json.dumps(
                    packet,
                    ensure_ascii=False
                )
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
                attempts,
                packet_json

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

    def get_pending_count(
        self,
        sender_node,
        receiver_node
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            SELECT COUNT(*)

            FROM pending_messages

            WHERE sender_node=?
            AND receiver_node=?
            """,
            (
                sender_node,
                receiver_node
            )
        )

        row = cursor.fetchone()

        if row:
            return row[0]

        return 0

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
