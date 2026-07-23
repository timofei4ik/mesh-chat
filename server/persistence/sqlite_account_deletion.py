try:
    from server.account_deletion import (
        AccountDataPolicy,
        AccountDeletionContext,
        AccountDeletionOrchestrator,
    )
except ModuleNotFoundError:
    from account_deletion import (
        AccountDataPolicy,
        AccountDeletionContext,
        AccountDeletionOrchestrator,
    )


def _placeholders(values):
    return ",".join("?" for _ in values)


class SQLiteAccountDeletionContextLoader:
    def __init__(self, connection):
        self._connection = connection

    def load(self, login):
        nodes = [
            row[0]
            for row in self._connection.execute(
                "SELECT node_id FROM account_devices WHERE login=?",
                (login,),
            ).fetchall()
            if row[0]
        ]
        account_node = self._connection.execute(
            "SELECT node_id FROM accounts WHERE login=?",
            (login,),
        ).fetchone()
        if account_node and account_node[0] and account_node[0] not in nodes:
            nodes.append(account_node[0])

        owned_group_ids = []
        if nodes:
            owned_group_ids = [
                row[0]
                for row in self._connection.execute(
                    "SELECT group_id FROM server_groups "
                    f"WHERE owner_node IN ({_placeholders(nodes)})",
                    nodes,
                ).fetchall()
            ]

        file_conditions = [
            "sender_login=?",
            "receiver_login=?",
        ]
        file_arguments = [login, login]
        if owned_group_ids:
            file_conditions.append(
                f"group_id IN ({_placeholders(owned_group_ids)})"
            )
            file_arguments.extend(owned_group_ids)
        stored_paths = [
            row[0]
            for row in self._connection.execute(
                "SELECT storage_path FROM server_files WHERE "
                + " OR ".join(file_conditions)
                + " UNION SELECT storage_path FROM file_transfer_sessions "
                "WHERE account_login=?",
                (*file_arguments, login),
            ).fetchall()
            if row[0]
        ]
        transfer_ids = [
            row[0]
            for row in self._connection.execute(
                """
                SELECT transfer_id
                FROM file_transfer_sessions
                WHERE account_login=?
                """,
                (login,),
            ).fetchall()
        ]
        return AccountDeletionContext(
            login=login,
            nodes=nodes,
            owned_group_ids=owned_group_ids,
            stored_paths=stored_paths,
            transfer_ids=transfer_ids,
        )


class SQLiteIdentityDeletionOwner:
    name = "identity"
    policies = (
        AccountDataPolicy("identity", "account_devices"),
        AccountDataPolicy("identity", "email_auth_challenges"),
        AccountDataPolicy("identity", "account_email_trusted_devices"),
        AccountDataPolicy("identity", "accounts"),
    )

    def __init__(self, connection):
        self._connection = connection

    def delete_account(self, context):
        for table in (
            "account_devices",
            "email_auth_challenges",
            "account_email_trusted_devices",
        ):
            self._connection.execute(
                f"DELETE FROM {table} WHERE login=?",
                (context.login,),
            )
        self._connection.execute(
            "DELETE FROM accounts WHERE login=?",
            (context.login,),
        )


class SQLiteChatSyncDeletionOwner:
    name = "chat_sync"
    policies = (
        AccountDataPolicy("chat_sync", "sync_events"),
        AccountDataPolicy("chat_sync", "sync_event_state"),
        AccountDataPolicy("chat_sync", "sync_cursors"),
        AccountDataPolicy("chat_sync", "processed_mutations"),
        AccountDataPolicy("chat_sync", "offline_packets", "delete_by_node"),
        AccountDataPolicy("chat_sync", "direct_messages"),
        AccountDataPolicy("chat_sync", "server_groups", "delete_owned"),
        AccountDataPolicy("chat_sync", "server_group_members"),
        AccountDataPolicy("chat_sync", "server_group_keys"),
        AccountDataPolicy("chat_sync", "server_group_messages"),
        AccountDataPolicy("chat_sync", "server_chat_deletes"),
        AccountDataPolicy("chat_sync", "server_reactions"),
        AccountDataPolicy("chat_sync", "server_pins"),
        AccountDataPolicy("chat_sync", "server_stories"),
        AccountDataPolicy("chat_sync", "server_story_reactions"),
        AccountDataPolicy("chat_sync", "server_story_views"),
        AccountDataPolicy("chat_sync", "server_sticker_libraries"),
        AccountDataPolicy("chat_sync", "account_chat_preferences"),
    )

    def __init__(self, connection):
        self._connection = connection

    def delete_account(self, context):
        for group_id in context.owned_group_ids:
            for table in (
                "server_group_keys",
                "server_group_messages",
                "server_group_members",
                "server_groups",
            ):
                self._connection.execute(
                    f"DELETE FROM {table} WHERE group_id=?",
                    (group_id,),
                )

        for table in (
            "sync_events",
            "sync_event_state",
            "sync_cursors",
            "processed_mutations",
        ):
            self._connection.execute(
                f"DELETE FROM {table} WHERE account_login=?",
                (context.login,),
            )
        self._connection.execute(
            """
            DELETE FROM direct_messages
            WHERE sender_login=? OR receiver_login=?
            """,
            (context.login, context.login),
        )
        self._connection.execute(
            "DELETE FROM server_group_messages WHERE sender_login=?",
            (context.login,),
        )
        self._connection.execute(
            "DELETE FROM server_group_members WHERE login=?",
            (context.login,),
        )
        self._connection.execute(
            "DELETE FROM server_group_keys WHERE member_login=?",
            (context.login,),
        )
        self._connection.execute(
            """
            DELETE FROM server_chat_deletes
            WHERE owner_login=? OR peer_login=?
            """,
            (context.login, context.login),
        )
        self._connection.execute(
            "DELETE FROM server_reactions WHERE reactor_login=?",
            (context.login,),
        )
        self._connection.execute(
            "DELETE FROM server_pins WHERE pinner_login=?",
            (context.login,),
        )

        story_ids = [
            row[0]
            for row in self._connection.execute(
                "SELECT story_id FROM server_stories WHERE owner_login=?",
                (context.login,),
            ).fetchall()
        ]
        for story_id in story_ids:
            self._connection.execute(
                "DELETE FROM server_story_reactions WHERE story_id=?",
                (story_id,),
            )
            self._connection.execute(
                "DELETE FROM server_story_views WHERE story_id=?",
                (story_id,),
            )
        self._connection.execute(
            "DELETE FROM server_stories WHERE owner_login=?",
            (context.login,),
        )
        self._connection.execute(
            "DELETE FROM server_story_reactions WHERE reactor_login=?",
            (context.login,),
        )
        self._connection.execute(
            "DELETE FROM server_story_views WHERE viewer_login=?",
            (context.login,),
        )
        self._connection.execute(
            "DELETE FROM server_sticker_libraries WHERE login=?",
            (context.login,),
        )
        self._connection.execute(
            "DELETE FROM account_chat_preferences WHERE login=?",
            (context.login,),
        )
        if context.nodes:
            self._connection.execute(
                "DELETE FROM offline_packets "
                f"WHERE destination_node IN ({_placeholders(context.nodes)})",
                context.nodes,
            )


class SQLiteMediaDeletionOwner:
    name = "media"
    policies = (
        AccountDataPolicy("media", "server_files"),
        AccountDataPolicy("media", "file_transfer_sessions"),
        AccountDataPolicy("media", "file_transfer_chunks"),
    )

    def __init__(self, connection):
        self._connection = connection

    def delete_account(self, context):
        for group_id in context.owned_group_ids:
            self._connection.execute(
                "DELETE FROM server_files WHERE group_id=?",
                (group_id,),
            )
        self._connection.execute(
            """
            DELETE FROM server_files
            WHERE sender_login=? OR receiver_login=?
            """,
            (context.login, context.login),
        )
        self._connection.execute(
            "DELETE FROM file_transfer_chunks WHERE account_login=?",
            (context.login,),
        )
        self._connection.execute(
            "DELETE FROM file_transfer_sessions WHERE account_login=?",
            (context.login,),
        )


class SQLiteSubscriptionDeletionOwner:
    name = "subscriptions"
    policies = (
        AccountDataPolicy("subscriptions", "account_subscriptions"),
        AccountDataPolicy("subscriptions", "subscription_events"),
        AccountDataPolicy("subscriptions", "subscription_orders"),
        AccountDataPolicy("subscriptions", "boosty_telegram_links"),
        AccountDataPolicy(
            "subscriptions",
            "boosty_activation_codes",
            "release",
        ),
        AccountDataPolicy("subscriptions", "meshpro_usage"),
        AccountDataPolicy("subscriptions", "account_meshpro_preferences"),
    )

    def __init__(self, connection):
        self._connection = connection

    def delete_account(self, context):
        for table in (
            "account_subscriptions",
            "subscription_events",
            "subscription_orders",
            "boosty_telegram_links",
            "meshpro_usage",
            "account_meshpro_preferences",
        ):
            self._connection.execute(
                f"DELETE FROM {table} WHERE login=?",
                (context.login,),
            )
        self._connection.execute(
            """
            UPDATE boosty_activation_codes
            SET redeemed_login=''
            WHERE redeemed_login=?
            """,
            (context.login,),
        )


class SQLiteVpnDeletionOwner:
    name = "vpn"
    policies = (
        AccountDataPolicy("vpn", "vpn_peers"),
        AccountDataPolicy("vpn", "service_sessions"),
    )

    def __init__(self, connection):
        self._connection = connection

    def delete_account(self, context):
        for table in ("vpn_peers", "service_sessions"):
            self._connection.execute(
                f"DELETE FROM {table} WHERE login=?",
                (context.login,),
            )


class SQLiteAiDeletionOwner:
    name = "ai"
    policies = (
        AccountDataPolicy("ai", "ai_voice_transcriptions"),
        AccountDataPolicy("ai", "ai_image_ocr"),
    )

    def __init__(self, connection):
        self._connection = connection

    def delete_account(self, context):
        for table in ("ai_voice_transcriptions", "ai_image_ocr"):
            self._connection.execute(
                f"DELETE FROM {table} WHERE login=?",
                (context.login,),
            )


class SQLitePushDeletionOwner:
    name = "push"
    policies = (
        AccountDataPolicy("push", "web_push_subscriptions"),
        AccountDataPolicy("push", "android_push_tokens"),
    )

    def __init__(self, connection):
        self._connection = connection

    def delete_account(self, context):
        for table in ("web_push_subscriptions", "android_push_tokens"):
            self._connection.execute(
                f"DELETE FROM {table} WHERE login=?",
                (context.login,),
            )


class SQLiteAutomationDeletionOwner:
    name = "automation"
    policies = (
        AccountDataPolicy("automation", "scheduled_messages"),
    )

    def __init__(self, connection):
        self._connection = connection

    def delete_account(self, context):
        self._connection.execute(
            "DELETE FROM scheduled_messages WHERE owner_login=?",
            (context.login,),
        )


def build_sqlite_account_deletion_orchestrator(
    connection,
    transaction_factory,
    pending_path_factory=None,
):
    return AccountDeletionOrchestrator(
        SQLiteAccountDeletionContextLoader(connection),
        [
            SQLiteChatSyncDeletionOwner(connection),
            SQLiteMediaDeletionOwner(connection),
            SQLiteSubscriptionDeletionOwner(connection),
            SQLiteVpnDeletionOwner(connection),
            SQLiteAiDeletionOwner(connection),
            SQLitePushDeletionOwner(connection),
            SQLiteAutomationDeletionOwner(connection),
            SQLiteIdentityDeletionOwner(connection),
        ],
        transaction_factory,
        pending_path_factory=pending_path_factory,
    )
