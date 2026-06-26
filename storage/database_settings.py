class DatabaseSettingsMixin:
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

        def get_draft(
        self,
        scope
    ):

            return self.get_setting(
                f"draft:{scope}",
                ""
            ) or ""

        def set_draft(
        self,
        scope,
        text
    ):

            key = f"draft:{scope}"
            cursor = self.conn.cursor()

            if text:

                cursor.execute(
                    """
                    INSERT OR REPLACE
                    INTO settings(key, value)
                    VALUES(?, ?)
                    """,
                    (
                        key,
                        text
                    )
                )

            else:

                cursor.execute(
                    "DELETE FROM settings WHERE key=?",
                    (key,)
                )

            self.conn.commit()

        def is_chat_archived(
        self,
        scope
    ):

            return self.get_setting(
                f"chat_archived:{scope}",
                "0"
            ) == "1"

        def set_chat_archived(
        self,
        scope,
        archived
    ):

            self.set_setting(
                f"chat_archived:{scope}",
                "1" if archived else "0"
            )

        def is_chat_pinned(
        self,
        scope
    ):

            return self.get_setting(
                f"chat_pinned:{scope}",
                "0"
            ) == "1"

        def set_chat_pinned(
        self,
        scope,
        pinned
    ):

            self.set_setting(
                f"chat_pinned:{scope}",
                "1" if pinned else "0"
            )

        def is_chat_muted(
        self,
        scope
    ):

            return self.get_setting(
                f"chat_muted:{scope}",
                "0"
            ) == "1"

        def set_chat_muted(
        self,
        scope,
        muted
    ):

            self.set_setting(
                f"chat_muted:{scope}",
                "1" if muted else "0"
            )
