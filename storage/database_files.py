class DatabaseFilesMixin:
    def save_file(
    self,
    sender_node,
    receiver_node,
    filename,
    data,
    file_id=None,
    timestamp=None
    ):

        cursor = self.conn.cursor()

        cursor.execute(
            """
            INSERT OR IGNORE INTO files(
                file_id,
                sender_node,
                receiver_node,
                filename,
                data,
                timestamp
            )
            VALUES(?,?,?,?,?,COALESCE(
                ?,
                STRFTIME('%Y-%m-%d %H:%M:%f', 'now')
            ))
            """,
            (
                file_id,
                sender_node,
                receiver_node,
                filename,
                data,
                timestamp
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
