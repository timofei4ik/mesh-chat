import hashlib
import json
import os
import re
import shutil
import sqlite3
from contextlib import contextmanager

try:
    from server.config import DB_PATH
except ModuleNotFoundError:
    from config import DB_PATH


OFFLINE_QUEUE_PACKET_TYPES = frozenset(
    {
        "chat_request",
        "chat_response",
        "group_join_request",
        "group_join_response",
        "message_received",
        "message_edit",
        "group_message_edit",
        "message_delete",
        "group_message_delete",
        "chat_delete",
        "group_delete",
    }
)
OFFLINE_PACKET_MAX_AGE_DAYS = 30
FILE_TRANSFER_MAX_BYTES = 96 * 1024 * 1024
FILE_TRANSFER_MAX_CHUNK_BYTES = 256 * 1024
FILE_TRANSFER_MAX_CHUNKS = 4096
FILE_TRANSFER_STALE_DAYS = 7
PROFILE_BLINK_SHAPE_ALIASES = {
    "auto": "auto",
    "dot": "dot",
    "point": "dot",
    "circle": "dot",
    "star": "star",
    "stars": "star",
    "sparkle": "star",
    "sparkles": "star",
    "moose": "moose",
    "elk": "moose",
}
PROFILE_BACKGROUND_ALIASES = {
    "mesh": "mesh",
    "default": "mesh",
    "aurora": "aurora",
    "starlight": "starlight",
    "stardust": "stardust",
    "ember": "ember",
    "sunset": "sunset",
    "frost": "frost",
    "orbit": "orbit",
}
PROFILE_EFFECT_ALIASES = {
    "stars": "stars",
    "star": "stars",
    "sparkle": "stars",
    "sparkles": "stars",
    "nodes": "nodes",
    "node": "nodes",
    "mesh": "nodes",
    "orbit": "orbit",
    "orbits": "orbit",
}
AVATAR_DECORATION_ALIASES = {
    "none": "none",
    "off": "none",
    "default": "none",
    "stardust": "stardust",
    "stars": "stardust",
    "ember": "ember",
    "ember_flame": "ember",
    "flame": "ember",
    "fire": "ember",
    "sunset": "sunset_clouds",
    "sunset_clouds": "sunset_clouds",
    "clouds": "sunset_clouds",
    "orbit": "neon_orbit",
    "neon_orbit": "neon_orbit",
    "frost": "frost_bloom",
    "frost_bloom": "frost_bloom",
}


class ServerStorageMixin:
    def _commit_storage(self):
        if getattr(self, "_storage_transaction_depth", 0) <= 0:
            self.db.commit()

    @contextmanager
    def atomic_storage_transaction(self):
        depth = getattr(self, "_storage_transaction_depth", 0)
        if depth > 0:
            self._storage_transaction_depth = depth + 1
            try:
                yield
            finally:
                self._storage_transaction_depth = depth
            return

        if self.db.in_transaction:
            raise RuntimeError(
                "atomic storage transaction requires a clean connection"
            )

        self.db.execute("BEGIN IMMEDIATE")
        self._storage_transaction_depth = 1
        try:
            yield
        except BaseException:
            self.db.rollback()
            raise
        else:
            self.db.commit()
        finally:
            self._storage_transaction_depth = 0

    def _looks_like_node_id(
        self,
        node_id
    ):
        value = (node_id or "").strip()
        if not value:
            return False
        return re.match(
            r"^[0-9a-fA-F]{8}-"
            r"[0-9a-fA-F]{4}-"
            r"[0-9a-fA-F]{4}-"
            r"[0-9a-fA-F]{4}-"
            r"[0-9a-fA-F]{12}$",
            value
        ) is not None

    def _is_legacy_owner_placeholder(
        self,
        node_id
    ):
        value = (node_id or "").strip()
        return bool(value) and len(value) <= 12 and not self._looks_like_node_id(value)

    def open_db(self):

        DB_PATH.parent.mkdir(
            parents=True,
            exist_ok=True
        )

        conn = sqlite3.connect(
            DB_PATH,
            check_same_thread=False
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS offline_packets(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                destination_node TEXT NOT NULL,
                packet_json TEXT NOT NULL,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS accounts(
                login TEXT PRIMARY KEY,
                password_salt TEXT NOT NULL,
                password_hash TEXT NOT NULL,
                node_id TEXT,
                display_name TEXT,
                public_username TEXT,
                about TEXT,
                avatar_data TEXT,
                encryption_public_key TEXT,
                encryption_recovery TEXT DEFAULT '',
                profile_background TEXT DEFAULT 'mesh',
                profile_effect TEXT DEFAULT 'stars',
                profile_blink_shape TEXT DEFAULT 'auto',
                avatar_decoration TEXT DEFAULT 'none',
                profile_glow INTEGER NOT NULL DEFAULT 0,
                profile_accent INTEGER NOT NULL DEFAULT 4282557941,
                emoji_status TEXT DEFAULT '',
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                last_login DATETIME
            )
            """
        )

        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_offline_packets_destination_id
            ON offline_packets(destination_node, id)
            """
        )

        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_offline_packets_created_at
            ON offline_packets(created_at)
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS sync_events(
                event_id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_login TEXT NOT NULL,
                operation_id TEXT NOT NULL,
                packet_type TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                UNIQUE(account_login, operation_id, packet_type)
            )
            """
        )

        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_sync_events_account_cursor
            ON sync_events(account_login, event_id)
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS sync_event_state(
                account_login TEXT PRIMARY KEY,
                retained_floor INTEGER NOT NULL DEFAULT 0,
                latest_cursor INTEGER NOT NULL DEFAULT 0,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        conn.execute(
            """
            INSERT OR IGNORE INTO sync_event_state(
                account_login,
                retained_floor,
                latest_cursor
            )
            SELECT account_login,
                   0,
                   MAX(event_id)
            FROM sync_events
            GROUP BY account_login
            """
        )

        conn.execute(
            """
            UPDATE sync_event_state
            SET latest_cursor=MAX(
                    latest_cursor,
                    COALESCE(
                        (
                            SELECT MAX(event_id)
                            FROM sync_events
                            WHERE account_login=sync_event_state.account_login
                        ),
                        0
                    )
                )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS sync_cursors(
                account_login TEXT NOT NULL,
                node_id TEXT NOT NULL,
                cursor INTEGER NOT NULL DEFAULT 0,
                acknowledged_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(account_login, node_id)
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS processed_mutations(
                account_login TEXT NOT NULL,
                outbox_id TEXT NOT NULL,
                operation_id TEXT NOT NULL DEFAULT '',
                packet_type TEXT NOT NULL DEFAULT '',
                packet_id TEXT NOT NULL DEFAULT '',
                processed_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(account_login, outbox_id)
            )
            """
        )

        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_processed_mutations_processed_at
            ON processed_mutations(processed_at)
            """
        )

        cursor = conn.execute(
            "PRAGMA table_info(accounts)"
        )

        account_columns = {
            row[1]
            for row in cursor.fetchall()
        }

        if "about" not in account_columns:

            conn.execute(
                "ALTER TABLE accounts ADD COLUMN about TEXT"
            )

        if "public_username" not in account_columns:

            conn.execute(
                "ALTER TABLE accounts ADD COLUMN public_username TEXT"
            )

        if "avatar_data" not in account_columns:

            conn.execute(
                "ALTER TABLE accounts ADD COLUMN avatar_data TEXT"
            )

        if "encryption_public_key" not in account_columns:

            conn.execute(
                "ALTER TABLE accounts ADD COLUMN encryption_public_key TEXT"
            )

        if "encryption_recovery" not in account_columns:

            conn.execute(
                "ALTER TABLE accounts ADD COLUMN "
                "encryption_recovery TEXT DEFAULT ''"
            )

        if "profile_background" not in account_columns:

            conn.execute(
                "ALTER TABLE accounts ADD COLUMN "
                "profile_background TEXT DEFAULT 'mesh'"
            )

        if "profile_effect" not in account_columns:

            conn.execute(
                "ALTER TABLE accounts ADD COLUMN "
                "profile_effect TEXT DEFAULT 'stars'"
            )

        if "profile_blink_shape" not in account_columns:

            conn.execute(
                "ALTER TABLE accounts ADD COLUMN "
                "profile_blink_shape TEXT DEFAULT 'auto'"
            )

        if "avatar_decoration" not in account_columns:

            conn.execute(
                "ALTER TABLE accounts ADD COLUMN "
                "avatar_decoration TEXT DEFAULT 'none'"
            )

        if "profile_glow" not in account_columns:

            conn.execute(
                "ALTER TABLE accounts ADD COLUMN "
                "profile_glow INTEGER NOT NULL DEFAULT 0"
            )

        if "profile_accent" not in account_columns:

            conn.execute(
                "ALTER TABLE accounts ADD COLUMN "
                "profile_accent INTEGER NOT NULL DEFAULT 4282557941"
            )

        if "emoji_status" not in account_columns:

            conn.execute(
                "ALTER TABLE accounts ADD COLUMN emoji_status TEXT DEFAULT ''"
            )

        conn.execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_public_username
            ON accounts(public_username)
            WHERE public_username IS NOT NULL
            AND public_username != ''
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS account_devices(
                login TEXT NOT NULL,
                node_id TEXT NOT NULL,
                display_name TEXT,
                device_name TEXT,
                custom_name TEXT,
                app_version TEXT,
                online INTEGER NOT NULL DEFAULT 0,
                revoked INTEGER NOT NULL DEFAULT 0,
                last_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(login, node_id)
            )
            """
        )
        device_columns = {
            row[1]
            for row in conn.execute("PRAGMA table_info(account_devices)")
        }
        if "device_name" not in device_columns:
            conn.execute(
                "ALTER TABLE account_devices ADD COLUMN device_name TEXT"
            )
        if "custom_name" not in device_columns:
            conn.execute(
                "ALTER TABLE account_devices ADD COLUMN custom_name TEXT"
            )
        if "revoked" not in device_columns:
            conn.execute(
                "ALTER TABLE account_devices "
                "ADD COLUMN revoked INTEGER NOT NULL DEFAULT 0"
            )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS account_subscriptions(
                login TEXT NOT NULL,
                product TEXT NOT NULL,
                plan_code TEXT NOT NULL DEFAULT 'none',
                status TEXT NOT NULL DEFAULT 'inactive',
                current_period_start DATETIME,
                current_period_end DATETIME,
                cancel_at_period_end INTEGER NOT NULL DEFAULT 0,
                provider TEXT NOT NULL DEFAULT 'manual',
                provider_customer_id TEXT NOT NULL DEFAULT '',
                provider_subscription_id TEXT NOT NULL DEFAULT '',
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(login, product),
                FOREIGN KEY(login) REFERENCES accounts(login) ON DELETE CASCADE
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS subscription_events(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                login TEXT NOT NULL,
                product TEXT NOT NULL,
                event_type TEXT NOT NULL,
                provider_event_id TEXT,
                payload_json TEXT NOT NULL DEFAULT '{}',
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        conn.execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_subscription_provider_event
            ON subscription_events(provider_event_id)
            WHERE provider_event_id IS NOT NULL
              AND provider_event_id != ''
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS subscription_orders(
                order_id TEXT PRIMARY KEY,
                checkout_key TEXT NOT NULL UNIQUE,
                login TEXT NOT NULL,
                product TEXT NOT NULL,
                plan_code TEXT NOT NULL,
                duration_days INTEGER NOT NULL,
                amount_value TEXT NOT NULL,
                currency TEXT NOT NULL DEFAULT 'RUB',
                provider TEXT NOT NULL,
                provider_payment_id TEXT,
                status TEXT NOT NULL DEFAULT 'creating',
                confirmation_url TEXT NOT NULL DEFAULT '',
                payment_method_id TEXT NOT NULL DEFAULT '',
                buyer_email TEXT NOT NULL DEFAULT '',
                provider_product_id TEXT NOT NULL DEFAULT '',
                provider_offer_id TEXT NOT NULL DEFAULT '',
                paid_at DATETIME,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY(login) REFERENCES accounts(login) ON DELETE CASCADE
            )
            """
        )

        subscription_order_columns = {
            row[1]
            for row in conn.execute(
                "PRAGMA table_info(subscription_orders)"
            ).fetchall()
        }
        for column_name, definition in (
            ("buyer_email", "TEXT NOT NULL DEFAULT ''"),
            ("provider_product_id", "TEXT NOT NULL DEFAULT ''"),
            ("provider_offer_id", "TEXT NOT NULL DEFAULT ''"),
        ):
            if column_name not in subscription_order_columns:
                conn.execute(
                    f"ALTER TABLE subscription_orders "
                    f"ADD COLUMN {column_name} {definition}"
                )

        conn.execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_subscription_order_payment
            ON subscription_orders(provider, provider_payment_id)
            WHERE provider_payment_id IS NOT NULL
              AND provider_payment_id != ''
            """
        )

        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_subscription_orders_login
            ON subscription_orders(login, product, created_at)
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS boosty_telegram_links(
                telegram_user_id INTEGER PRIMARY KEY,
                login TEXT NOT NULL UNIQUE,
                telegram_username TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL DEFAULT 'active',
                verified_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                last_checked_at DATETIME,
                access_expires_at DATETIME,
                revoked_at DATETIME,
                last_error TEXT NOT NULL DEFAULT '',
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY(login) REFERENCES accounts(login) ON DELETE CASCADE
            )
            """
        )

        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_boosty_links_status_check
            ON boosty_telegram_links(status, last_checked_at)
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS boosty_activation_codes(
                code_hash TEXT PRIMARY KEY,
                telegram_user_id INTEGER NOT NULL,
                telegram_username TEXT NOT NULL DEFAULT '',
                duration_days INTEGER NOT NULL DEFAULT 30,
                issue_kind TEXT NOT NULL DEFAULT 'legacy',
                expires_at DATETIME NOT NULL,
                consumed_at DATETIME,
                redeemed_login TEXT NOT NULL DEFAULT '',
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        boosty_code_columns = {
            row[1]
            for row in conn.execute(
                "PRAGMA table_info(boosty_activation_codes)"
            ).fetchall()
        }
        if "duration_days" not in boosty_code_columns:
            conn.execute(
                "ALTER TABLE boosty_activation_codes "
                "ADD COLUMN duration_days INTEGER NOT NULL DEFAULT 30"
            )
        if "issue_kind" not in boosty_code_columns:
            conn.execute(
                "ALTER TABLE boosty_activation_codes "
                "ADD COLUMN issue_kind TEXT NOT NULL DEFAULT 'legacy'"
            )
        if "redeemed_login" not in boosty_code_columns:
            conn.execute(
                "ALTER TABLE boosty_activation_codes "
                "ADD COLUMN redeemed_login TEXT NOT NULL DEFAULT ''"
            )

        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_boosty_codes_user_expiry
            ON boosty_activation_codes(
                telegram_user_id,
                expires_at,
                consumed_at
            )
            """
        )

        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_boosty_codes_user_kind_created
            ON boosty_activation_codes(
                telegram_user_id,
                issue_kind,
                created_at
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS boosty_key_recipients(
                telegram_user_id INTEGER PRIMARY KEY,
                private_chat_id INTEGER NOT NULL,
                telegram_username TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL DEFAULT 'pending',
                last_membership_check_at DATETIME,
                last_key_issued_at DATETIME,
                next_key_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                last_error TEXT NOT NULL DEFAULT '',
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_boosty_recipients_due
            ON boosty_key_recipients(status, next_key_at)
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS vpn_peers(
                peer_id TEXT PRIMARY KEY,
                login TEXT NOT NULL,
                product TEXT NOT NULL DEFAULT 'meshpro',
                device_id TEXT NOT NULL,
                address TEXT NOT NULL,
                public_key TEXT NOT NULL,
                config_path TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'provisioning',
                last_applied_at DATETIME,
                revoked_at DATETIME,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY(login) REFERENCES accounts(login) ON DELETE CASCADE,
                UNIQUE(login, product, device_id)
            )
            """
        )

        conn.execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_vpn_peers_active_address
            ON vpn_peers(product, address)
            WHERE status != 'revoked'
            """
        )

        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_vpn_peers_subscription
            ON vpn_peers(login, product, status)
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS service_sessions(
                token_hash TEXT PRIMARY KEY,
                login TEXT NOT NULL,
                service TEXT NOT NULL,
                device_id TEXT NOT NULL DEFAULT '',
                expires_at DATETIME NOT NULL,
                last_used_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                revoked_at DATETIME,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY(login) REFERENCES accounts(login) ON DELETE CASCADE
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS meshpro_usage(
                login TEXT NOT NULL,
                feature_id TEXT NOT NULL,
                period_key TEXT NOT NULL,
                used_count INTEGER NOT NULL DEFAULT 0,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(login, feature_id, period_key),
                FOREIGN KEY(login) REFERENCES accounts(login) ON DELETE CASCADE
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS ai_voice_transcriptions(
                login TEXT NOT NULL,
                message_id TEXT NOT NULL,
                text TEXT NOT NULL,
                language TEXT NOT NULL DEFAULT '',
                duration_seconds REAL NOT NULL DEFAULT 0,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(login, message_id),
                FOREIGN KEY(login) REFERENCES accounts(login) ON DELETE CASCADE
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS ai_image_ocr(
                login TEXT NOT NULL,
                message_id TEXT NOT NULL,
                text TEXT NOT NULL DEFAULT '',
                language TEXT NOT NULL DEFAULT '',
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(login, message_id),
                FOREIGN KEY(login) REFERENCES accounts(login) ON DELETE CASCADE
            )
            """
        )

        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_service_sessions_login_service
            ON service_sessions(login, service, expires_at)
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS web_push_subscriptions(
                endpoint TEXT PRIMARY KEY,
                login TEXT,
                node_id TEXT NOT NULL,
                subscription_json TEXT NOT NULL,
                user_agent TEXT,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS direct_messages(
                message_id TEXT PRIMARY KEY,
                sender_node TEXT,
                sender_login TEXT,
                sender_name TEXT,
                receiver_node TEXT,
                receiver_login TEXT,
                message TEXT,
                reply_to_message_id TEXT,
                reply_to_text TEXT,
                message_effect TEXT DEFAULT 'none',
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )
        cursor = conn.execute(
            "PRAGMA table_info(direct_messages)"
        )
        direct_columns = {
            row[1] for row in cursor.fetchall()
        }
        if "reply_to_message_id" not in direct_columns:
            conn.execute(
                "ALTER TABLE direct_messages ADD COLUMN reply_to_message_id TEXT"
            )
        if "reply_to_text" not in direct_columns:
            conn.execute(
                "ALTER TABLE direct_messages ADD COLUMN reply_to_text TEXT"
            )
        if "chat_kind" not in direct_columns:
            conn.execute(
                "ALTER TABLE direct_messages ADD COLUMN chat_kind TEXT DEFAULT 'normal'"
            )
        if "chat_id" not in direct_columns:
            conn.execute(
                "ALTER TABLE direct_messages ADD COLUMN chat_id TEXT DEFAULT ''"
            )
        if "message_effect" not in direct_columns:
            conn.execute(
                "ALTER TABLE direct_messages ADD COLUMN message_effect TEXT DEFAULT 'none'"
            )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS server_groups(
                group_id TEXT PRIMARY KEY,
                group_name TEXT,
                group_about TEXT DEFAULT '',
                group_avatar_data TEXT DEFAULT '',
                members_json TEXT,
                owner_node TEXT,
                admins_json TEXT DEFAULT '[]',
                is_channel INTEGER DEFAULT 0,
                comments_enabled INTEGER DEFAULT 1,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        cursor = conn.execute(
            "PRAGMA table_info(server_groups)"
        )

        group_columns = {
            row[1]
            for row in cursor.fetchall()
        }

        if "owner_node" not in group_columns:

            conn.execute(
                "ALTER TABLE server_groups ADD COLUMN owner_node TEXT"
            )

        if "group_about" not in group_columns:

            conn.execute(
                "ALTER TABLE server_groups ADD COLUMN group_about TEXT DEFAULT ''"
            )

        if "group_avatar_data" not in group_columns:

            conn.execute(
                "ALTER TABLE server_groups ADD COLUMN group_avatar_data TEXT DEFAULT ''"
            )

        if "admins_json" not in group_columns:

            conn.execute(
                "ALTER TABLE server_groups ADD COLUMN admins_json TEXT DEFAULT '[]'"
            )

        if "is_channel" not in group_columns:

            conn.execute(
                "ALTER TABLE server_groups ADD COLUMN is_channel INTEGER DEFAULT 0"
            )

        if "comments_enabled" not in group_columns:

            conn.execute(
                "ALTER TABLE server_groups ADD COLUMN comments_enabled INTEGER DEFAULT 1"
            )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS server_group_members(
                group_id TEXT,
                node_id TEXT,
                login TEXT,
                PRIMARY KEY(group_id, node_id)
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS server_group_keys(
                group_id TEXT,
                key_id TEXT,
                member_node TEXT,
                member_login TEXT,
                key_envelope TEXT NOT NULL,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(group_id, key_id, member_node)
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS server_group_messages(
                message_id TEXT PRIMARY KEY,
                group_id TEXT,
                group_name TEXT,
                sender_node TEXT,
                sender_login TEXT,
                sender_name TEXT,
                message TEXT,
                reply_to_message_id TEXT,
                reply_to_text TEXT,
                members_json TEXT,
                group_key_id TEXT,
                message_effect TEXT DEFAULT 'none',
                is_channel_comment INTEGER DEFAULT 0,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS server_chat_deletes(
                owner_node TEXT NOT NULL,
                peer_node TEXT NOT NULL,
                owner_login TEXT DEFAULT '',
                peer_login TEXT DEFAULT '',
                chat_kind TEXT DEFAULT 'normal',
                chat_id TEXT DEFAULT '',
                deleted_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(owner_node, peer_node, chat_kind, chat_id)
            )
            """
        )
        cursor = conn.execute(
            "PRAGMA table_info(server_chat_deletes)"
        )
        chat_delete_columns = {
            row[1] for row in cursor.fetchall()
        }
        if "chat_kind" not in chat_delete_columns:
            conn.execute(
                "ALTER TABLE server_chat_deletes ADD COLUMN chat_kind TEXT DEFAULT 'normal'"
            )
        if "chat_id" not in chat_delete_columns:
            conn.execute(
                "ALTER TABLE server_chat_deletes ADD COLUMN chat_id TEXT DEFAULT ''"
            )
        if "owner_login" not in chat_delete_columns:
            conn.execute(
                "ALTER TABLE server_chat_deletes ADD COLUMN owner_login TEXT DEFAULT ''"
            )
        if "peer_login" not in chat_delete_columns:
            conn.execute(
                "ALTER TABLE server_chat_deletes ADD COLUMN peer_login TEXT DEFAULT ''"
            )
        cursor = conn.execute(
            "PRAGMA table_info(server_chat_deletes)"
        )
        chat_delete_pk = [
            row[1]
            for row in sorted(
                cursor.fetchall(),
                key=lambda item: item[5]
            )
            if row[5]
        ]
        if chat_delete_pk == ["owner_node", "peer_node"]:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS server_chat_deletes_new(
                    owner_node TEXT NOT NULL,
                    peer_node TEXT NOT NULL,
                    owner_login TEXT DEFAULT '',
                    peer_login TEXT DEFAULT '',
                    chat_kind TEXT DEFAULT 'normal',
                    chat_id TEXT DEFAULT '',
                    deleted_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY(owner_node, peer_node, chat_kind, chat_id)
                )
                """
            )
            conn.execute(
                """
                INSERT OR IGNORE INTO server_chat_deletes_new(
                    owner_node,
                    peer_node,
                    owner_login,
                    peer_login,
                    chat_kind,
                    chat_id,
                    deleted_at
                )
                SELECT owner_node,
                       peer_node,
                       COALESCE(owner_login, ''),
                       COALESCE(peer_login, ''),
                       COALESCE(chat_kind, 'normal'),
                       COALESCE(chat_id, ''),
                       deleted_at
                FROM server_chat_deletes
                """
            )
            conn.execute("DROP TABLE server_chat_deletes")
            conn.execute(
                "ALTER TABLE server_chat_deletes_new RENAME TO server_chat_deletes"
            )

        conn.execute(
            """
            UPDATE server_chat_deletes
            SET owner_login=COALESCE(
                    NULLIF(owner_login, ''),
                    (SELECT login
                     FROM account_devices
                     WHERE node_id=server_chat_deletes.owner_node
                     LIMIT 1),
                    (SELECT login
                     FROM accounts
                     WHERE node_id=server_chat_deletes.owner_node
                     LIMIT 1),
                    ''
                ),
                peer_login=COALESCE(
                    NULLIF(peer_login, ''),
                    (SELECT login
                     FROM account_devices
                     WHERE node_id=server_chat_deletes.peer_node
                     LIMIT 1),
                    (SELECT login
                     FROM accounts
                     WHERE node_id=server_chat_deletes.peer_node
                     LIMIT 1),
                    ''
                )
            """
        )

        cursor = conn.execute(
            "PRAGMA table_info(server_group_messages)"
        )
        if "group_key_id" not in {
            row[1] for row in cursor.fetchall()
        }:
            conn.execute(
                "ALTER TABLE server_group_messages ADD COLUMN group_key_id TEXT"
            )
        cursor = conn.execute(
            "PRAGMA table_info(server_group_messages)"
        )
        group_message_columns = {
            row[1] for row in cursor.fetchall()
        }
        if "reply_to_message_id" not in group_message_columns:
            conn.execute(
                "ALTER TABLE server_group_messages ADD COLUMN reply_to_message_id TEXT"
            )
        if "reply_to_text" not in group_message_columns:
            conn.execute(
                "ALTER TABLE server_group_messages ADD COLUMN reply_to_text TEXT"
            )
        if "message_effect" not in group_message_columns:
            conn.execute(
                "ALTER TABLE server_group_messages ADD COLUMN message_effect TEXT DEFAULT 'none'"
            )
        if "is_channel_comment" not in group_message_columns:
            conn.execute(
                "ALTER TABLE server_group_messages ADD COLUMN is_channel_comment INTEGER DEFAULT 0"
            )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS server_reactions(
                scope TEXT,
                message_id TEXT,
                reactor_node TEXT,
                reactor_login TEXT,
                reactor_identity TEXT NOT NULL DEFAULT '',
                reaction TEXT,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(scope, message_id, reactor_node, reaction)
            )
            """
        )

        reaction_columns = {
            row[1]
            for row in conn.execute(
                "PRAGMA table_info(server_reactions)"
            ).fetchall()
        }
        if "reactor_identity" not in reaction_columns:
            conn.execute(
                """
                ALTER TABLE server_reactions
                ADD COLUMN reactor_identity TEXT NOT NULL DEFAULT ''
                """
            )
        conn.execute(
            """
            UPDATE server_reactions
            SET reactor_login=COALESCE(
                    NULLIF(LOWER(TRIM(reactor_login)), ''),
                    (SELECT LOWER(TRIM(login))
                     FROM account_devices
                     WHERE node_id=server_reactions.reactor_node
                     LIMIT 1),
                    (SELECT LOWER(TRIM(login))
                     FROM accounts
                     WHERE node_id=server_reactions.reactor_node
                     LIMIT 1),
                    ''
                )
            """
        )
        conn.execute(
            """
            UPDATE server_reactions
            SET reactor_identity=CASE
                WHEN COALESCE(reactor_login, '')!=''
                    THEN 'login:' || LOWER(TRIM(reactor_login))
                ELSE 'node:' || COALESCE(reactor_node, '')
            END
            """
        )
        conn.execute(
            """
            DELETE FROM server_reactions
            WHERE rowid NOT IN (
                SELECT MIN(rowid)
                FROM server_reactions
                GROUP BY scope,
                         message_id,
                         reactor_identity,
                         reaction
            )
            """
        )
        conn.execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS
                idx_server_reactions_account_unique
            ON server_reactions(
                scope,
                message_id,
                reactor_identity,
                reaction
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS server_files(
                file_id TEXT PRIMARY KEY,
                sender_node TEXT,
                sender_login TEXT,
                sender_name TEXT,
                receiver_node TEXT,
                receiver_login TEXT,
                group_id TEXT,
                group_name TEXT DEFAULT '',
                is_channel INTEGER DEFAULT 0,
                comments_enabled INTEGER DEFAULT 1,
                filename TEXT,
                caption TEXT,
                reply_to_message_id TEXT DEFAULT '',
                reply_to_text TEXT DEFAULT '',
                is_channel_comment INTEGER DEFAULT 0,
                data TEXT,
                group_key_id TEXT,
                message_kind TEXT DEFAULT 'file',
                message_effect TEXT DEFAULT 'none',
                storage_path TEXT DEFAULT '',
                sha256 TEXT DEFAULT '',
                size_bytes INTEGER DEFAULT 0,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS file_transfer_sessions(
                account_login TEXT NOT NULL,
                transfer_id TEXT NOT NULL,
                operation_id TEXT NOT NULL DEFAULT '',
                source_node TEXT NOT NULL,
                destination_node TEXT NOT NULL,
                file_id TEXT NOT NULL,
                total_chunks INTEGER NOT NULL,
                chunk_size INTEGER NOT NULL,
                size_bytes INTEGER NOT NULL,
                sha256 TEXT NOT NULL,
                metadata_json TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'receiving',
                storage_path TEXT NOT NULL DEFAULT '',
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(account_login, transfer_id)
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS file_transfer_chunks(
                account_login TEXT NOT NULL,
                transfer_id TEXT NOT NULL,
                chunk_index INTEGER NOT NULL,
                size_bytes INTEGER NOT NULL,
                sha256 TEXT NOT NULL,
                chunk_path TEXT NOT NULL,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(account_login, transfer_id, chunk_index),
                FOREIGN KEY(account_login, transfer_id)
                    REFERENCES file_transfer_sessions(account_login, transfer_id)
                    ON DELETE CASCADE
            )
            """
        )

        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_file_transfer_sessions_status
            ON file_transfer_sessions(status, updated_at)
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS server_pins(
                scope TEXT,
                message_id TEXT,
                pinner_node TEXT,
                pinner_login TEXT,
                text TEXT,
                group_key_id TEXT,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(scope, message_id)
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS server_stories(
                story_id TEXT PRIMARY KEY,
                owner_node TEXT,
                owner_login TEXT,
                story_json TEXT NOT NULL,
                recipients_json TEXT DEFAULT '[]',
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS server_story_reactions(
                story_id TEXT,
                reactor_node TEXT,
                reactor_login TEXT,
                reaction TEXT,
                liked INTEGER DEFAULT 1,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(story_id, reactor_node, reaction)
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS server_story_views(
                story_id TEXT,
                viewer_node TEXT,
                viewer_login TEXT,
                viewed_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(story_id, viewer_node)
            )
            """
        )

        cursor = conn.execute(
            "PRAGMA table_info(server_pins)"
        )
        if "group_key_id" not in {
            row[1] for row in cursor.fetchall()
        }:
            conn.execute(
                "ALTER TABLE server_pins ADD COLUMN group_key_id TEXT"
            )

        cursor = conn.execute(
            "PRAGMA table_info(server_files)"
        )
        if "group_key_id" not in {
            row[1] for row in cursor.fetchall()
        }:
            conn.execute(
                "ALTER TABLE server_files ADD COLUMN group_key_id TEXT"
            )

        cursor = conn.execute(
            "PRAGMA table_info(server_files)"
        )
        if "caption" not in {
            row[1] for row in cursor.fetchall()
        }:
            conn.execute(
                "ALTER TABLE server_files ADD COLUMN caption TEXT"
            )
        cursor = conn.execute(
            "PRAGMA table_info(server_files)"
        )
        file_columns = {
            row[1] for row in cursor.fetchall()
        }
        if "chat_kind" not in file_columns:
            conn.execute(
                "ALTER TABLE server_files ADD COLUMN chat_kind TEXT DEFAULT 'normal'"
            )
        if "chat_id" not in file_columns:
            conn.execute(
                "ALTER TABLE server_files ADD COLUMN chat_id TEXT DEFAULT ''"
            )
        if "message_kind" not in file_columns:
            conn.execute(
                "ALTER TABLE server_files ADD COLUMN message_kind TEXT DEFAULT 'file'"
            )
        if "group_name" not in file_columns:
            conn.execute(
                "ALTER TABLE server_files ADD COLUMN group_name TEXT DEFAULT ''"
            )
        if "is_channel" not in file_columns:
            conn.execute(
                "ALTER TABLE server_files ADD COLUMN is_channel INTEGER DEFAULT 0"
            )
        if "comments_enabled" not in file_columns:
            conn.execute(
                "ALTER TABLE server_files ADD COLUMN comments_enabled INTEGER DEFAULT 1"
            )
        if "reply_to_message_id" not in file_columns:
            conn.execute(
                "ALTER TABLE server_files ADD COLUMN reply_to_message_id TEXT DEFAULT ''"
            )
        if "reply_to_text" not in file_columns:
            conn.execute(
                "ALTER TABLE server_files ADD COLUMN reply_to_text TEXT DEFAULT ''"
            )
        if "is_channel_comment" not in file_columns:
            conn.execute(
                "ALTER TABLE server_files ADD COLUMN is_channel_comment INTEGER DEFAULT 0"
            )
        if "message_effect" not in file_columns:
            conn.execute(
                "ALTER TABLE server_files ADD COLUMN message_effect TEXT DEFAULT 'none'"
            )
        if "storage_path" not in file_columns:
            conn.execute(
                "ALTER TABLE server_files ADD COLUMN storage_path TEXT DEFAULT ''"
            )
        if "sha256" not in file_columns:
            conn.execute(
                "ALTER TABLE server_files ADD COLUMN sha256 TEXT DEFAULT ''"
            )
        if "size_bytes" not in file_columns:
            conn.execute(
                "ALTER TABLE server_files ADD COLUMN size_bytes INTEGER DEFAULT 0"
            )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS server_sticker_libraries(
                login TEXT PRIMARY KEY,
                library_json TEXT NOT NULL,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        housekeeping = self.run_storage_housekeeping(conn)

        conn.commit()

        removed_total = sum(housekeeping.values())

        if removed_total:
            print(
                "Storage housekeeping:",
                ", ".join(
                    f"{name}={count}"
                    for name, count in housekeeping.items()
                    if count
                )
            )

        return conn

    def meshpro_usage_count(self, login, feature_id, period_key):
        row = self.db.execute(
            """
            SELECT used_count
            FROM meshpro_usage
            WHERE login=? AND feature_id=? AND period_key=?
            """,
            (
                str(login or "").strip().lower(),
                str(feature_id or "").strip().lower(),
                str(period_key or "").strip(),
            ),
        ).fetchone()
        return max(0, int(row[0])) if row else 0

    def reserve_meshpro_usage(
        self,
        login,
        feature_id,
        period_key,
        limit,
        amount=1,
    ):
        normalized_login = str(login or "").strip().lower()
        normalized_feature = str(feature_id or "").strip().lower()
        normalized_period = str(period_key or "").strip()
        normalized_limit = max(0, int(limit or 0))
        normalized_amount = max(1, int(amount or 1))
        if (
            not normalized_login
            or not normalized_feature
            or not normalized_period
            or normalized_limit <= 0
        ):
            return False
        cursor = self.db.execute(
            """
            INSERT INTO meshpro_usage(
                login,
                feature_id,
                period_key,
                used_count,
                updated_at
            )
            VALUES(?, ?, ?, ?, CURRENT_TIMESTAMP)
            ON CONFLICT(login, feature_id, period_key) DO UPDATE SET
                used_count=meshpro_usage.used_count + excluded.used_count,
                updated_at=CURRENT_TIMESTAMP
            WHERE meshpro_usage.used_count + excluded.used_count <= ?
            """,
            (
                normalized_login,
                normalized_feature,
                normalized_period,
                normalized_amount,
                normalized_limit,
            ),
        )
        self.db.commit()
        return cursor.rowcount > 0

    def release_meshpro_usage(
        self,
        login,
        feature_id,
        period_key,
        amount=1,
    ):
        normalized_amount = max(1, int(amount or 1))
        self.db.execute(
            """
            UPDATE meshpro_usage
            SET used_count=MAX(used_count - ?, 0),
                updated_at=CURRENT_TIMESTAMP
            WHERE login=? AND feature_id=? AND period_key=?
            """,
            (
                normalized_amount,
                str(login or "").strip().lower(),
                str(feature_id or "").strip().lower(),
                str(period_key or "").strip(),
            ),
        )
        self.db.commit()

    def get_ai_voice_transcription(self, login, message_id):
        row = self.db.execute(
            """
            SELECT text, language, duration_seconds
            FROM ai_voice_transcriptions
            WHERE login=? AND message_id=?
            """,
            (
                str(login or "").strip().lower(),
                str(message_id or "").strip(),
            ),
        ).fetchone()
        if not row:
            return None
        return {
            "text": row[0] or "",
            "language": row[1] or "",
            "duration_seconds": max(0.0, float(row[2] or 0)),
        }

    def save_ai_voice_transcription(
        self,
        login,
        message_id,
        text,
        language="",
        duration_seconds=0,
    ):
        self.db.execute(
            """
            INSERT INTO ai_voice_transcriptions(
                login,
                message_id,
                text,
                language,
                duration_seconds,
                updated_at
            )
            VALUES(?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
            ON CONFLICT(login, message_id) DO UPDATE SET
                text=excluded.text,
                language=excluded.language,
                duration_seconds=excluded.duration_seconds,
                updated_at=CURRENT_TIMESTAMP
            """,
            (
                str(login or "").strip().lower(),
                str(message_id or "").strip(),
                str(text or "").strip(),
                str(language or "").strip().lower(),
                max(0.0, float(duration_seconds or 0)),
            ),
        )
        self.db.commit()

    def get_ai_image_ocr(self, login, message_id):
        row = self.db.execute(
            """
            SELECT text, language
            FROM ai_image_ocr
            WHERE login=? AND message_id=?
            """,
            (
                str(login or "").strip().lower(),
                str(message_id or "").strip(),
            ),
        ).fetchone()
        if not row:
            return None
        return {
            "text": row[0] or "",
            "language": row[1] or "",
            "processed": True,
        }

    def save_ai_image_ocr(self, login, message_id, text, language=""):
        self.db.execute(
            """
            INSERT INTO ai_image_ocr(
                login,
                message_id,
                text,
                language,
                updated_at
            )
            VALUES(?, ?, ?, ?, CURRENT_TIMESTAMP)
            ON CONFLICT(login, message_id) DO UPDATE SET
                text=excluded.text,
                language=excluded.language,
                updated_at=CURRENT_TIMESTAMP
            """,
            (
                str(login or "").strip().lower(),
                str(message_id or "").strip(),
                str(text or "").strip(),
                str(language or "").strip().lower(),
            ),
        )
        self.db.commit()

    def run_storage_housekeeping(self, connection=None):

        conn = connection or self.db
        stats = {
            "server_packets": 0,
            "unsupported_packets": 0,
            "expired_packets": 0,
            "orphan_reactions": 0,
            "expired_service_sessions": 0,
            "expired_processed_mutations": 0,
            "expired_file_transfers": 0,
            "expired_file_transfer_receipts": 0,
        }

        cursor = conn.execute(
            """
            DELETE FROM service_sessions
            WHERE expires_at <= CURRENT_TIMESTAMP
               OR (
                    revoked_at IS NOT NULL
                    AND revoked_at < DATETIME('now', '-7 days')
               )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS android_push_tokens(
                token TEXT PRIMARY KEY,
                login TEXT,
                node_id TEXT NOT NULL,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )
        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_android_push_tokens_node
            ON android_push_tokens(node_id)
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS account_chat_preferences(
                login TEXT NOT NULL,
                chat_key TEXT NOT NULL,
                theme_id TEXT NOT NULL DEFAULT 'midnight',
                bubble_style TEXT NOT NULL DEFAULT 'classic',
                animated_background INTEGER NOT NULL DEFAULT 1,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(login, chat_key)
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS account_meshpro_preferences(
                login TEXT PRIMARY KEY,
                quick_reactions_json TEXT NOT NULL DEFAULT '[]',
                hd_audio INTEGER NOT NULL DEFAULT 1,
                enhanced_noise_suppression INTEGER NOT NULL DEFAULT 1,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS scheduled_messages(
                schedule_id TEXT PRIMARY KEY,
                owner_login TEXT NOT NULL,
                source_node TEXT NOT NULL,
                payloads_json TEXT NOT NULL,
                preview_text TEXT NOT NULL DEFAULT '',
                chat_key TEXT NOT NULL DEFAULT '',
                repeat_interval TEXT NOT NULL DEFAULT 'none',
                next_run_at DATETIME NOT NULL,
                last_run_at DATETIME,
                run_count INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL DEFAULT 'active',
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_scheduled_messages_due
            ON scheduled_messages(status, next_run_at)
            """
        )
        stats["expired_service_sessions"] = max(cursor.rowcount, 0)

        cursor = conn.execute(
            """
            DELETE FROM processed_mutations
            WHERE processed_at < DATETIME('now', '-90 days')
            """
        )
        stats["expired_processed_mutations"] = max(cursor.rowcount, 0)

        rows = conn.execute(
            """
            SELECT id,
                   destination_node,
                   packet_json,
                   created_at < DATETIME('now', ?) AS expired
            FROM offline_packets
            """,
            (
                f"-{OFFLINE_PACKET_MAX_AGE_DAYS} days",
            )
        ).fetchall()

        packet_ids_to_delete = []

        for packet_id, destination_node, packet_json, expired in rows:

            if str(destination_node or "").strip().upper() == "SERVER":
                stats["server_packets"] += 1
                packet_ids_to_delete.append((packet_id,))
                continue

            try:
                packet = json.loads(packet_json)
            except (TypeError, ValueError, json.JSONDecodeError):
                packet = None

            packet_type = (
                str(packet.get("type") or "")
                if isinstance(packet, dict)
                else ""
            )

            if packet_type not in OFFLINE_QUEUE_PACKET_TYPES:
                stats["unsupported_packets"] += 1
                packet_ids_to_delete.append((packet_id,))
                continue

            if expired:
                stats["expired_packets"] += 1
                packet_ids_to_delete.append((packet_id,))

        if packet_ids_to_delete:
            conn.executemany(
                "DELETE FROM offline_packets WHERE id=?",
                packet_ids_to_delete
            )

        cursor = conn.execute(
            """
            DELETE FROM server_reactions
            WHERE NOT EXISTS(
                SELECT 1
                FROM direct_messages
                WHERE direct_messages.message_id=server_reactions.message_id
            )
            AND NOT EXISTS(
                SELECT 1
                FROM server_group_messages
                WHERE server_group_messages.message_id=server_reactions.message_id
            )
            AND NOT EXISTS(
                SELECT 1
                FROM server_files
                WHERE server_files.file_id=server_reactions.message_id
            )
            """
        )
        stats["orphan_reactions"] = max(cursor.rowcount, 0)

        stale_transfers = conn.execute(
            """
            SELECT account_login, transfer_id
            FROM file_transfer_sessions
            WHERE status!='complete'
              AND updated_at < DATETIME('now', ?)
            """,
            (f"-{FILE_TRANSFER_STALE_DAYS} days",),
        ).fetchall()
        for account_login, transfer_id in stale_transfers:
            conn.execute(
                """
                DELETE FROM file_transfer_chunks
                WHERE account_login=? AND transfer_id=?
                """,
                (account_login, transfer_id),
            )
            conn.execute(
                """
                DELETE FROM file_transfer_sessions
                WHERE account_login=? AND transfer_id=?
                """,
                (account_login, transfer_id),
            )
            shutil.rmtree(
                self._file_transfer_pending_path(account_login, transfer_id),
                ignore_errors=True,
            )
        stats["expired_file_transfers"] = len(stale_transfers)

        cursor = conn.execute(
            """
            DELETE FROM file_transfer_sessions
            WHERE status='complete'
              AND updated_at < DATETIME('now', '-30 days')
            """
        )
        stats["expired_file_transfer_receipts"] = max(cursor.rowcount, 0)

        if connection is None:
            conn.commit()

        return stats

    def save_web_push_subscription(
        self,
        login,
        node_id,
        subscription,
        user_agent=""
    ):

        if not node_id or not isinstance(subscription, dict):
            return

        endpoint = subscription.get("endpoint")

        if not endpoint:
            return

        self.db.execute(
            """
            INSERT INTO web_push_subscriptions(
                endpoint,
                login,
                node_id,
                subscription_json,
                user_agent,
                updated_at
            )
            VALUES(?,?,?,?,?,CURRENT_TIMESTAMP)
            ON CONFLICT(endpoint) DO UPDATE SET
                login=excluded.login,
                node_id=excluded.node_id,
                subscription_json=excluded.subscription_json,
                user_agent=excluded.user_agent,
                updated_at=CURRENT_TIMESTAMP
            """,
            (
                endpoint,
                login,
                node_id,
                json.dumps(subscription, ensure_ascii=False),
                user_agent or ""
            )
        )

        self.db.commit()

    def delete_web_push_subscription(
        self,
        endpoint=None,
        node_id=None
    ):

        if endpoint:
            self.db.execute(
                "DELETE FROM web_push_subscriptions WHERE endpoint=?",
                (endpoint,)
            )
        elif node_id:
            self.db.execute(
                "DELETE FROM web_push_subscriptions WHERE node_id=?",
                (node_id,)
            )
        else:
            return

        self.db.commit()

    def web_push_subscriptions_for_node(
        self,
        node_id
    ):

        if not node_id:
            return []

        cursor = self.db.execute(
            """
            SELECT endpoint, subscription_json
            FROM web_push_subscriptions
            WHERE node_id=?
            """,
            (node_id,)
        )

        rows = []

        for endpoint, subscription_json in cursor.fetchall():
            try:
                rows.append(
                    (
                        endpoint,
                        json.loads(subscription_json)
                    )
                )
            except json.JSONDecodeError:
                self.delete_web_push_subscription(endpoint=endpoint)

        return rows

    def save_android_push_token(self, login, node_id, token):

        normalized = str(token or "").strip()
        if not node_id or not normalized:
            return

        self.db.execute(
            """
            DELETE FROM android_push_tokens
            WHERE node_id=? AND token<>?
            """,
            (node_id, normalized)
        )
        self.db.execute(
            """
            INSERT INTO android_push_tokens(
                token,
                login,
                node_id,
                updated_at
            )
            VALUES(?,?,?,CURRENT_TIMESTAMP)
            ON CONFLICT(token) DO UPDATE SET
                login=excluded.login,
                node_id=excluded.node_id,
                updated_at=CURRENT_TIMESTAMP
            """,
            (normalized, login, node_id)
        )
        self.db.commit()

    def delete_android_push_token(self, token=None, node_id=None):

        normalized = str(token or "").strip()
        if normalized:
            self.db.execute(
                "DELETE FROM android_push_tokens WHERE token=?",
                (normalized,)
            )
        elif node_id:
            self.db.execute(
                "DELETE FROM android_push_tokens WHERE node_id=?",
                (node_id,)
            )
        else:
            return
        self.db.commit()

    def android_push_tokens_for_node(self, node_id):

        if not node_id:
            return []
        cursor = self.db.execute(
            """
            SELECT token
            FROM android_push_tokens
            WHERE node_id=?
            ORDER BY updated_at DESC
            """,
            (node_id,)
        )
        return [row[0] for row in cursor.fetchall() if row[0]]

    def save_account_device(
        self,
        login,
        node_id,
        display_name=None,
        app_version=None,
        online=True,
        device_name=None
    ):

        login = (
            login
            or ""
        ).strip().lower()

        if not login or not node_id:
            return

        self.db.execute(
            """
            INSERT INTO account_devices(
                login,
                node_id,
                display_name,
                device_name,
                app_version,
                online,
                last_seen
            )
            VALUES(?,?,?,?,?,?,CURRENT_TIMESTAMP)
            ON CONFLICT(login, node_id) DO UPDATE SET
                display_name=COALESCE(excluded.display_name, display_name),
                device_name=COALESCE(excluded.device_name, device_name),
                app_version=COALESCE(excluded.app_version, app_version),
                online=excluded.online,
                last_seen=CURRENT_TIMESTAMP
            """,
            (
                login,
                node_id,
                display_name,
                device_name,
                app_version,
                1 if online else 0
            )
        )

        self.db.commit()

    def set_account_device_online(
        self,
        login,
        node_id,
        online
    ):

        login = (
            login
            or ""
        ).strip().lower()

        if not login or not node_id:
            return

        self.db.execute(
            """
            UPDATE account_devices
            SET online=?,
                last_seen=CURRENT_TIMESTAMP
            WHERE login=?
              AND node_id=?
            """,
            (
                1 if online else 0,
                login,
                node_id
            )
        )

        self.db.commit()

    def get_account_devices(
        self,
        login
    ):

        login = (
            login
            or ""
        ).strip().lower()

        if not login:
            return []

        cursor = self.db.cursor()
        cursor.execute(
            """
            SELECT node_id,
                   display_name,
                   COALESCE(custom_name, device_name, display_name),
                   app_version,
                   online,
                   revoked,
                   last_seen
            FROM account_devices
            WHERE login=?
            ORDER BY online DESC,
                     last_seen DESC
            """,
            (
                login,
            )
        )

        return [
            {
                "node_id": row[0],
                "display_name": row[1],
                "device_name": row[2] or "",
                "app_version": row[3],
                "online": bool(row[4]) and not bool(row[5]),
                "revoked": bool(row[5]),
                "last_seen": row[6]
            }
            for row in cursor.fetchall()
        ]

    def is_account_device_revoked(self, login, node_id):
        login = str(login or "").strip().lower()
        node_id = str(node_id or "").strip()
        if not login or not node_id:
            return False
        row = self.db.execute(
            """
            SELECT revoked
            FROM account_devices
            WHERE login=? AND node_id=?
            LIMIT 1
            """,
            (login, node_id),
        ).fetchone()
        return bool(row and row[0])

    def reactivate_account_device(self, login, node_id):
        login = str(login or "").strip().lower()
        node_id = str(node_id or "").strip()
        if not login or not node_id:
            return
        self.db.execute(
            """
            UPDATE account_devices
            SET revoked=0,
                last_seen=CURRENT_TIMESTAMP
            WHERE login=? AND node_id=?
            """,
            (login, node_id),
        )
        self.db.commit()

    def update_account_device(
        self,
        login,
        target_node,
        action,
        custom_name=None,
    ):
        login = str(login or "").strip().lower()
        target_node = str(target_node or "").strip()
        action = str(action or "").strip().lower()
        if not login or not target_node:
            return False, "invalid_device"
        row = self.db.execute(
            """
            SELECT 1
            FROM account_devices
            WHERE login=? AND node_id=?
            LIMIT 1
            """,
            (login, target_node),
        ).fetchone()
        if not row:
            return False, "device_not_found"
        if action == "revoke":
            self.db.execute(
                """
                UPDATE account_devices
                SET revoked=1,
                    online=0,
                    last_seen=CURRENT_TIMESTAMP
                WHERE login=? AND node_id=?
                """,
                (login, target_node),
            )
            self.delete_android_push_token(node_id=target_node)
            self.delete_web_push_subscription(node_id=target_node)
        elif action == "rename":
            if not self.subscription_feature_enabled(
                login,
                "multi_device_plus",
            ):
                return False, "meshpro_required"
            normalized_name = re.sub(
                r"[\r\n\t]+",
                " ",
                str(custom_name or "").strip(),
            )[:48].strip()
            self.db.execute(
                """
                UPDATE account_devices
                SET custom_name=?,
                    last_seen=CURRENT_TIMESTAMP
                WHERE login=? AND node_id=?
                """,
                (normalized_name or None, login, target_node),
            )
        else:
            return False, "unsupported_action"
        self._commit_storage()
        return True, "ok"

    def get_account_node_ids(
        self,
        login
    ):
        return [
            device["node_id"]
            for device in self.get_account_devices(login)
            if device.get("node_id")
        ]

    def get_online_account_nodes(
        self,
        login
    ):

        login = (
            login
            or ""
        ).strip().lower()

        if not login:
            return []

        cursor = self.db.cursor()
        cursor.execute(
            """
            SELECT node_id
            FROM account_devices
            WHERE login=?
              AND online=1
              AND revoked=0
            ORDER BY last_seen DESC
            """,
            (
                login,
            )
        )

        return [
            row[0]
            for row in cursor.fetchall()
            if row[0]
        ]

    def save_account_profile(
        self,
        login,
        node_id,
        display_name,
        public_username=None,
        about=None,
        avatar_data=None,
        encryption_public_key=None,
        profile_background=None,
        profile_effect=None,
        profile_blink_shape=None,
        avatar_decoration=None,
        profile_glow=None,
        profile_accent=None,
        emoji_status=None
    ):

        authenticated_login = (
            self.get_login_by_node(node_id)
            or ""
        ).strip().lower()
        requested_login = (
            login
            or ""
        ).strip().lower()

        if (
            authenticated_login
            and requested_login
            and authenticated_login != requested_login
        ):
            return False, "profile login does not match authenticated account"

        login = authenticated_login or requested_login

        if not login:
            return False, "missing authenticated account"

        if profile_background is not None:
            profile_background = str(profile_background).strip().lower()
            profile_background = PROFILE_BACKGROUND_ALIASES.get(
                profile_background,
                "mesh"
            )
            if not self.subscription_feature_enabled(
                login,
                "profile_background"
            ):
                return False, "meshpro_required"

        if profile_effect is not None:
            profile_effect = str(profile_effect).strip().lower()
            profile_effect = PROFILE_EFFECT_ALIASES.get(
                profile_effect,
                "nodes"
            )
            if not self.subscription_feature_enabled(login, "profile_effect"):
                return False, "meshpro_required"

        if profile_blink_shape is not None:
            profile_blink_shape = str(profile_blink_shape).strip().lower()
            profile_blink_shape = PROFILE_BLINK_SHAPE_ALIASES.get(
                profile_blink_shape,
                "dot"
            )
            if not self.subscription_feature_enabled(login, "profile_effect"):
                return False, "meshpro_required"

        if avatar_decoration is not None:
            avatar_decoration = str(avatar_decoration).strip().lower()
            avatar_decoration = AVATAR_DECORATION_ALIASES.get(
                avatar_decoration,
                "none"
            )
            if not self.subscription_feature_enabled(login, "animated_avatar"):
                return False, "meshpro_required"

        if profile_glow is not None:
            if isinstance(profile_glow, bool):
                profile_glow = profile_glow
            elif profile_glow in (0, 1):
                profile_glow = bool(profile_glow)
            else:
                return False, "invalid profile glow"
            if not self.subscription_feature_enabled(login, "profile_glow"):
                return False, "meshpro_required"

        if profile_accent is not None:
            try:
                profile_accent = int(profile_accent)
            except (TypeError, ValueError):
                return False, "invalid profile accent"
            if profile_accent < 0 or profile_accent > 0xFFFFFFFF:
                return False, "invalid profile accent"
            profile_accent = 0xFF000000 | (profile_accent & 0x00FFFFFF)
            if not self.subscription_feature_enabled(login, "custom_accent"):
                return False, "meshpro_required"

        if emoji_status is not None:
            emoji_status = str(emoji_status).strip()
            if len(emoji_status) > 16:
                return False, "emoji status is too long"
            if emoji_status and not self.subscription_feature_enabled(
                login,
                "emoji_status"
            ):
                return False, "meshpro_required"

        avatar_value = str(avatar_data or "").strip().lower()
        if (
            avatar_value.startswith("data:image/gif")
            and not self.subscription_feature_enabled(login, "animated_avatar")
        ):
            return False, "meshpro_required"

        if public_username is not None:

            public_username = (
                public_username
                or ""
            ).strip().lower().lstrip("@")

            cursor = self.db.cursor()
            cursor.execute(
                """
                SELECT login
                FROM accounts
                WHERE public_username=?
                AND login!=?
                """,
                (
                    public_username,
                    login
                )
            )

            if cursor.fetchone():
                print(
                    f"Username update rejected, already taken: {public_username}"
                )
                return False, "username is already taken"

        self.db.execute(
            """
            UPDATE accounts
            SET node_id=?,
                display_name=COALESCE(?, display_name),
                public_username=COALESCE(?, public_username),
                about=COALESCE(?, about),
                avatar_data=COALESCE(?, avatar_data),
                encryption_public_key=COALESCE(
                    ?,
                    encryption_public_key
                ),
                profile_background=COALESCE(?, profile_background),
                profile_effect=COALESCE(?, profile_effect),
                profile_blink_shape=COALESCE(?, profile_blink_shape),
                avatar_decoration=COALESCE(?, avatar_decoration),
                profile_glow=COALESCE(?, profile_glow),
                profile_accent=COALESCE(?, profile_accent),
                emoji_status=COALESCE(?, emoji_status),
                last_login=CURRENT_TIMESTAMP
            WHERE login=?
            """,
            (
                node_id,
                display_name,
                public_username,
                about,
                avatar_data,
                encryption_public_key,
                profile_background,
                profile_effect,
                profile_blink_shape,
                avatar_decoration,
                int(profile_glow) if profile_glow is not None else None,
                profile_accent,
                emoji_status,
                login
            )
        )

        self.db.commit()
        return True, "ok"

    def find_account_by_public_username(
        self,
        public_username
    ):

        username = (
            public_username
            or ""
        ).strip().lower().lstrip("@")

        if not username:
            return None

        cursor = self.db.cursor()
        cursor.execute(
            """
            SELECT a.login,
                   COALESCE(d.node_id, a.node_id) AS node_id,
                   a.display_name,
                   a.public_username,
                   a.about,
                   a.avatar_data,
                   a.encryption_public_key,
                   COALESCE(a.profile_background, 'mesh'),
                   COALESCE(a.profile_effect, 'stars'),
                   COALESCE(a.profile_blink_shape, 'auto'),
                   COALESCE(a.avatar_decoration, 'none'),
                   COALESCE(a.profile_glow, 0),
                   COALESCE(a.profile_accent, 4282557941)
            FROM accounts a
            LEFT JOIN account_devices d
              ON d.login=a.login
             AND d.node_id=(
                SELECT d2.node_id
                FROM account_devices d2
                WHERE d2.login=a.login
                ORDER BY d2.online DESC,
                         d2.last_seen DESC
                LIMIT 1
             )
            WHERE a.public_username=?
            """,
            (
                username,
            )
        )

        row = cursor.fetchone()

        if not row:
            return None

        premium_fields = self._meshpro_public_profile_fields(
            row[0],
            row[7],
            row[8],
            row[9],
            row[10],
            row[11],
            row[12]
        )

        return {
            "login": row[0],
            "node_id": row[1],
            "display_name": row[2],
            "public_username": row[3],
            "about": row[4],
            "avatar_data": row[5],
            "encryption_public_key": row[6],
            **premium_fields
        }

    def _meshpro_public_profile_fields(
        self,
        login,
        profile_background="mesh",
        profile_effect="nodes",
        profile_blink_shape="auto",
        avatar_decoration="none",
        profile_glow=False,
        profile_accent=4282557941
    ):
        status_getter = getattr(self, "subscription_status", None)
        if not callable(status_getter):
            features = {}
        else:
            status = status_getter(login)
            features = (
                status.get("entitlements", {}).get("features", {})
                if status.get("active")
                else {}
            )

        background = str(profile_background or "mesh").strip().lower()
        background = PROFILE_BACKGROUND_ALIASES.get(background, "mesh")
        effect = str(profile_effect or "nodes").strip().lower()
        effect = PROFILE_EFFECT_ALIASES.get(effect, "nodes")
        blink_shape = str(profile_blink_shape or "auto").strip().lower()
        blink_shape = PROFILE_BLINK_SHAPE_ALIASES.get(blink_shape, "auto")
        decoration = str(avatar_decoration or "none").strip().lower()
        decoration = AVATAR_DECORATION_ALIASES.get(decoration, "none")
        try:
            accent = int(profile_accent)
        except (TypeError, ValueError):
            accent = 4282557941
        accent = 0xFF000000 | (accent & 0x00FFFFFF)
        emoji_row = self.db.execute(
            "SELECT COALESCE(emoji_status, '') FROM accounts WHERE login=?",
            (login,)
        ).fetchone()
        emoji_status = str(emoji_row[0] or "").strip() if emoji_row else ""

        return {
            "meshpro_badge": bool(features.get("premium_badge")),
            "profile_background": (
                background
                if features.get("profile_background")
                else "mesh"
            ),
            "profile_effect": (
                effect
                if features.get("profile_effect")
                else "nodes"
            ),
            "profile_blink_shape": (
                blink_shape
                if features.get("profile_effect")
                else "auto"
            ),
            "avatar_decoration": (
                decoration
                if features.get("animated_avatar")
                else "none"
            ),
            "profile_glow": bool(
                profile_glow and features.get("profile_glow")
            ),
            "profile_accent": (
                accent
                if features.get("custom_accent")
                else 4282557941
            ),
            "emoji_status": (
                emoji_status
                if features.get("emoji_status")
                else ""
            )
        }

    def _meshpro_badge_enabled(self, login):
        return self._meshpro_public_profile_fields(login)["meshpro_badge"]

    def save_meshpro_preferences(
        self,
        login,
        quick_reactions,
        hd_audio,
        enhanced_noise_suppression,
    ):
        login = str(login or "").strip().lower()
        if not login:
            return False, "unauthorized"
        if not self.subscription_feature_enabled(
            login,
            "custom_quick_reactions",
        ):
            return False, "meshpro_required"
        status = self.subscription_status(login, "meshpro")
        reaction_limit = int(
            status.get("entitlements", {})
            .get("limits", {})
            .get("quick_reactions", 4)
        )
        normalized_reactions = []
        for raw_reaction in (
            quick_reactions if isinstance(quick_reactions, list) else []
        ):
            reaction = str(raw_reaction or "").strip()
            if not reaction or len(reaction) > 16:
                continue
            if reaction not in normalized_reactions:
                normalized_reactions.append(reaction)
            if len(normalized_reactions) >= reaction_limit:
                break
        if not normalized_reactions:
            normalized_reactions = [
                "\u2764\ufe0f",
                "\U0001f44c",
                "\U0001face",
                "\U0001f44d",
            ]
        normalized_hd_audio = bool(hd_audio) and self.subscription_feature_enabled(
            login,
            "call_hd_audio",
        )
        normalized_noise = bool(
            enhanced_noise_suppression
        ) and self.subscription_feature_enabled(
            login,
            "call_noise_suppression_plus",
        )
        self.db.execute(
            """
            INSERT INTO account_meshpro_preferences(
                login,
                quick_reactions_json,
                hd_audio,
                enhanced_noise_suppression,
                updated_at
            )
            VALUES(?,?,?,?,CURRENT_TIMESTAMP)
            ON CONFLICT(login) DO UPDATE SET
                quick_reactions_json=excluded.quick_reactions_json,
                hd_audio=excluded.hd_audio,
                enhanced_noise_suppression=excluded.enhanced_noise_suppression,
                updated_at=CURRENT_TIMESTAMP
            """,
            (
                login,
                json.dumps(normalized_reactions, ensure_ascii=False),
                1 if normalized_hd_audio else 0,
                1 if normalized_noise else 0,
            ),
        )
        self._commit_storage()
        return True, "ok"

    def get_meshpro_preferences(self, login):
        login = str(login or "").strip().lower()
        defaults = {
            "quick_reactions": [
                "\u2764\ufe0f",
                "\U0001f44c",
                "\U0001face",
                "\U0001f44d",
            ],
            "hd_audio": True,
            "enhanced_noise_suppression": True,
        }
        if not login:
            return defaults
        row = self.db.execute(
            """
            SELECT quick_reactions_json,
                   hd_audio,
                   enhanced_noise_suppression
            FROM account_meshpro_preferences
            WHERE login=?
            LIMIT 1
            """,
            (login,),
        ).fetchone()
        if not row:
            return defaults
        try:
            reactions = json.loads(row[0] or "[]")
        except json.JSONDecodeError:
            reactions = []
        if not isinstance(reactions, list):
            reactions = []
        normalized = []
        for item in reactions:
            reaction = str(item or "").strip()
            if reaction and len(reaction) <= 16 and reaction not in normalized:
                normalized.append(reaction)
        return {
            "quick_reactions": normalized or defaults["quick_reactions"],
            "hd_audio": bool(row[1]),
            "enhanced_noise_suppression": bool(row[2]),
        }

    def save_chat_preferences(
        self,
        login,
        chat_key,
        theme_id,
        bubble_style,
        animated_background
    ):
        login = str(login or "").strip().lower()
        chat_key = str(chat_key or "").strip()
        theme_id = str(theme_id or "midnight").strip().lower()
        bubble_style = str(bubble_style or "classic").strip().lower()
        if not login or not chat_key or len(chat_key) > 240:
            return False, "invalid chat preferences"
        if theme_id not in {"midnight", "cyan", "violet", "emerald"}:
            return False, "invalid chat theme"
        if bubble_style not in {"classic", "soft", "compact"}:
            return False, "invalid bubble style"
        if not self.subscription_feature_enabled(login, "per_chat_theme"):
            return False, "meshpro_required"
        if not self.subscription_feature_enabled(
            login,
            "custom_message_bubbles"
        ):
            return False, "meshpro_required"
        animated_background = bool(animated_background)
        if animated_background and not self.subscription_feature_enabled(
            login,
            "animated_chat_backgrounds"
        ):
            return False, "meshpro_required"
        self.db.execute(
            """
            INSERT INTO account_chat_preferences(
                login,
                chat_key,
                theme_id,
                bubble_style,
                animated_background,
                updated_at
            )
            VALUES(?,?,?,?,?,CURRENT_TIMESTAMP)
            ON CONFLICT(login, chat_key) DO UPDATE SET
                theme_id=excluded.theme_id,
                bubble_style=excluded.bubble_style,
                animated_background=excluded.animated_background,
                updated_at=CURRENT_TIMESTAMP
            """,
            (
                login,
                chat_key,
                theme_id,
                bubble_style,
                1 if animated_background else 0
            )
        )
        self.db.commit()
        return True, "ok"

    def get_chat_preferences(self, login):
        login = str(login or "").strip().lower()
        if not login:
            return []
        rows = self.db.execute(
            """
            SELECT chat_key,
                   theme_id,
                   bubble_style,
                   animated_background,
                   updated_at
            FROM account_chat_preferences
            WHERE login=?
            ORDER BY updated_at DESC
            """,
            (login,)
        ).fetchall()
        return [
            {
                "chat_key": row[0],
                "theme_id": row[1] or "midnight",
                "bubble_style": row[2] or "classic",
                "animated_background": row[3] == 1,
                "updated_at": row[4]
            }
            for row in rows
        ]

    def get_login_by_node(
        self,
        node_id
    ):

        cursor = self.db.cursor()

        cursor.execute(
            """
            SELECT login
            FROM accounts
            WHERE node_id=?
            """,
            (
                node_id,
            )
        )

        row = cursor.fetchone()

        if row:
            return row[0]

        cursor.execute(
            """
            SELECT login
            FROM account_devices
            WHERE node_id=?
            """,
            (
                node_id,
            )
        )

        row = cursor.fetchone()

        if row:
            return row[0]

        return None

    def _node_identity(
        self,
        node_id
    ):

        value = (node_id or "").strip()
        login = self.get_login_by_node(value)

        if login:
            return f"login:{login.strip().lower()}"

        return f"node:{value}"

    def _same_account_nodes(
        self,
        first_node,
        second_node
    ):

        first = (first_node or "").strip()
        second = (second_node or "").strip()

        if not first or not second:
            return False

        return self._node_identity(first) == self._node_identity(second)

    def _dedupe_account_nodes(
        self,
        nodes
    ):

        result = []
        identities = set()

        for node_id in nodes or []:
            value = (node_id or "").strip()
            if not value:
                continue
            identity = self._node_identity(value)
            if identity in identities:
                continue
            identities.add(identity)
            result.append(value)

        return result

    def get_profile_by_node(
        self,
        node_id
    ):

        cursor = self.db.cursor()

        cursor.execute(
            """
            SELECT a.login,
                   ? AS node_id,
                   a.display_name,
                   a.public_username,
                   a.about,
                   a.avatar_data,
                   a.encryption_public_key,
                   COALESCE(a.profile_background, 'mesh'),
                   COALESCE(a.profile_effect, 'stars'),
                   COALESCE(a.profile_blink_shape, 'auto'),
                   COALESCE(a.avatar_decoration, 'none'),
                   COALESCE(a.profile_glow, 0),
                   COALESCE(a.profile_accent, 4282557941)
            FROM accounts a
            LEFT JOIN account_devices d
              ON d.login=a.login
            WHERE a.node_id=? OR d.node_id=?
            LIMIT 1
            """,
            (
                node_id,
                node_id,
                node_id,
            )
        )

        row = cursor.fetchone()

        if not row:
            return {}

        premium_fields = self._meshpro_public_profile_fields(
            row[0],
            row[7],
            row[8],
            row[9],
            row[10],
            row[11],
            row[12]
        )

        return {
            "login": row[0],
            "node_id": row[1],
            "display_name": row[2],
            "public_username": row[3],
            "about": row[4],
            "avatar_data": row[5],
            "encryption_public_key": row[6],
            **premium_fields
        }

    def save_group_members(
        self,
        group_id,
        group_name,
        members,
        owner_node=None,
        admins=None,
        is_channel=False,
        comments_enabled=True,
        group_about=None,
        group_avatar_data=None
    ):

        if not group_id:
            return

        members = self._dedupe_account_nodes(
            members
        )

        existing_owner, existing_admins = self.get_group_roles(
            group_id
        )

        existing_meta = self.db.execute(
            """
            SELECT group_about,
                   group_avatar_data,
                   COALESCE(comments_enabled, 1)
            FROM server_groups
            WHERE group_id=?
            """,
            (
                group_id,
            )
        ).fetchone()
        existing_about = existing_meta[0] if existing_meta else ""
        existing_avatar = existing_meta[1] if existing_meta else ""
        existing_comments_enabled = (
            existing_meta[2] == 1
            if existing_meta
            else True
        )
        if comments_enabled is None:
            comments_enabled = existing_comments_enabled
        group_about = (
            group_about
            if group_about not in (None, "")
            else existing_about
        )
        group_avatar_data = (
            group_avatar_data
            if group_avatar_data not in (None, "")
            else existing_avatar
        )

        owner_node = (
            existing_owner
            or owner_node
            or ""
        )

        if (
            owner_node
            and not any(
                self._same_account_nodes(owner_node, member)
                for member in members
            )
        ):
            members.append(owner_node)

        if admins is None:
            admins = existing_admins

        admins = self._dedupe_account_nodes(
            admins
        )
        admins = [
            node_id
            for node_id in admins
            if any(
                self._same_account_nodes(node_id, member)
                for member in members
            )
            and not self._same_account_nodes(node_id, owner_node)
        ]

        self.db.execute(
            """
            INSERT OR REPLACE INTO server_groups(
                group_id,
                group_name,
                group_about,
                group_avatar_data,
                members_json,
                owner_node,
                admins_json,
                is_channel,
                comments_enabled,
                updated_at
            )
            VALUES(?,?,?,?,?,?,?,?,?,CURRENT_TIMESTAMP)
            """,
            (
                group_id,
                group_name or group_id,
                group_about or "",
                group_avatar_data or "",
                json.dumps(
                    members,
                    ensure_ascii=False
                ),
                owner_node,
                json.dumps(
                    admins,
                    ensure_ascii=False
                ),
                1 if is_channel else 0,
                1 if comments_enabled else 0
            )
        )

        self.db.execute(
            """
            DELETE FROM server_group_members
            WHERE group_id=?
            """,
            (
                group_id,
            )
        )

        for member in members:

            self.db.execute(
                """
                INSERT OR REPLACE INTO server_group_members(
                    group_id,
                    node_id,
                    login
                )
                VALUES(?,?,?)
                """,
                (
                    group_id,
                    member,
                    self.get_login_by_node(
                        member
                    )
                )
            )

        self.db.commit()

    def get_group_roles(
        self,
        group_id
    ):

        cursor = self.db.cursor()

        cursor.execute(
            """
            SELECT owner_node,
                   admins_json,
                   members_json
            FROM server_groups
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
        if self._is_legacy_owner_placeholder(owner_node):
            owner_node = ""

        try:
            admins = json.loads(
                row[1] or "[]"
            )
        except (TypeError, ValueError):
            admins = []

        return owner_node, admins

    def get_group_delivery_nodes(self, group_id):

        if not group_id:
            return []

        rows = self.db.execute(
            """
            SELECT node_id, login
            FROM server_group_members
            WHERE group_id=?
            """,
            (
                group_id,
            )
        ).fetchall()

        targets = set()
        for node_id, stored_login in rows:
            login = (
                stored_login
                or self.get_login_by_node(node_id)
                or ""
            ).strip().lower()
            if login:
                targets.update(self.get_account_node_ids(login))
            elif node_id:
                targets.add(node_id)

        return sorted(targets)

    def authorize_group_management(
        self,
        packet
    ):

        packet_type = packet.get(
            "type"
        )

        if packet_type not in (
            "group_update",
            "group_delete",
            "group_pin",
            "group_member_leave"
        ):
            return True

        group_id = packet.get(
            "group_id"
        )

        source_node = packet.get(
            "source_node"
        )

        owner_node, admins = self.get_group_roles(
            group_id
        )

        if packet_type == "group_member_leave":
            return (
                bool(source_node)
                and (
                    packet.get("leaver_node") in (None, "", source_node)
                )
            )

        if not owner_node:

            claimed_owner = packet.get(
                "owner_node"
            )
            source_login = self.get_login_by_node(source_node) or ""
            source_is_member = self.db.execute(
                """
                SELECT 1
                FROM server_group_members
                WHERE group_id=?
                  AND (node_id=? OR (login!='' AND login=?))
                LIMIT 1
                """,
                (
                    group_id,
                    source_node,
                    source_login
                )
            ).fetchone() is not None

            if packet_type == "group_delete":
                return source_is_member

            return (
                packet_type == "group_update"
                and source_node
                and (
                    self._same_account_nodes(source_node, claimed_owner)
                    or source_is_member
                )
            )

        if packet_type == "group_delete":
            return self._same_account_nodes(source_node, owner_node)

        if packet_type == "group_member_leave":
            return True

        if packet_type == "group_pin":
            return (
                self._same_account_nodes(source_node, owner_node)
                or any(
                    self._same_account_nodes(source_node, admin_node)
                    for admin_node in admins
                )
            )

        members = packet.get(
            "members"
        ) or []

        claimed_owner = packet.get(
            "owner_node"
        )

        claimed_admins = packet.get(
            "admins"
        ) or []

        if (
            not self._same_account_nodes(claimed_owner, owner_node)
            or not any(
                self._same_account_nodes(owner_node, member_node)
                for member_node in members
            )
        ):
            return False

        if self._same_account_nodes(source_node, owner_node):
            return True

        if not any(
            self._same_account_nodes(source_node, admin_node)
            for admin_node in admins
        ):
            return False

        return (
            {
                self._node_identity(node_id)
                for node_id in claimed_admins
            } == {
                self._node_identity(node_id)
                for node_id in admins
            }
            and all(
                any(
                    self._same_account_nodes(admin_node, member_node)
                    for member_node in members
                )
                for admin_node in admins
            )
        )

    def _file_transfer_root(self):

        root = DB_PATH.parent / f"{DB_PATH.stem}_file_storage"
        root.mkdir(parents=True, exist_ok=True)
        return root

    def _file_transfer_storage_key(self, account_login, transfer_id):

        return hashlib.sha256(
            f"{account_login}\0{transfer_id}".encode("utf-8")
        ).hexdigest()

    def _file_transfer_pending_path(self, account_login, transfer_id):

        return (
            self._file_transfer_root()
            / "pending"
            / self._file_transfer_storage_key(account_login, transfer_id)
        )

    def _atomic_write_bytes(self, destination, data):

        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_suffix(destination.suffix + ".tmp")
        with temporary.open("wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)

    def _file_transfer_ranges(self, indexes):

        ordered = sorted({int(index) for index in indexes if int(index) >= 0})
        if not ordered:
            return []
        ranges = []
        start = ordered[0]
        end = start
        for index in ordered[1:]:
            if index == end + 1:
                end = index
                continue
            ranges.append([start, end])
            start = index
            end = index
        ranges.append([start, end])
        return ranges

    def _file_transfer_result(
        self,
        *,
        ok,
        transfer_id,
        file_id,
        chunk_index=None,
        received_indexes=(),
        complete=False,
        newly_completed=False,
        retryable=False,
        reset=False,
        reason="",
        metadata=None,
        storage_path="",
        sha256="",
        size_bytes=0,
    ):

        return {
            "ok": bool(ok),
            "transfer_id": transfer_id,
            "file_id": file_id,
            "chunk_index": chunk_index,
            "received_ranges": self._file_transfer_ranges(received_indexes),
            "complete": bool(complete),
            "newly_completed": bool(newly_completed),
            "retryable": bool(retryable),
            "reset": bool(reset),
            "reason": reason,
            "metadata": metadata or {},
            "storage_path": storage_path or "",
            "sha256": sha256 or "",
            "size_bytes": int(size_bytes or 0),
        }

    def save_file_transfer_chunk(self, packet, account_login):

        account_login = str(account_login or "").strip().lower()
        transfer_id = str(packet.get("transfer_id") or "").strip()
        operation_id = str(packet.get("operation_id") or "").strip()
        file_id = str(packet.get("file_id") or "").strip()
        source_node = str(packet.get("source_node") or "").strip()
        destination_node = str(packet.get("destination_node") or "").strip()
        filename = str(packet.get("filename") or "").strip()
        sha256 = str(packet.get("file_sha256") or "").strip().lower()

        try:
            chunk_index = int(packet.get("chunk_index"))
            total_chunks = int(packet.get("total_chunks"))
            chunk_size = int(packet.get("chunk_size_bytes"))
            size_bytes = int(packet.get("file_size"))
        except (TypeError, ValueError):
            chunk_index = -1
            total_chunks = 0
            chunk_size = 0
            size_bytes = 0

        invalid_identity = (
            not account_login
            or not transfer_id
            or len(transfer_id) > 160
            or not file_id
            or len(file_id) > 256
            or not source_node
            or not destination_node
            or not filename
        )
        invalid_shape = (
            total_chunks < 1
            or total_chunks > FILE_TRANSFER_MAX_CHUNKS
            or chunk_index < 0
            or chunk_index >= total_chunks
            or chunk_size < 1
            or chunk_size > FILE_TRANSFER_MAX_CHUNK_BYTES
            or size_bytes < 1
            or size_bytes > FILE_TRANSFER_MAX_BYTES
            or total_chunks != (size_bytes + chunk_size - 1) // chunk_size
            or re.fullmatch(r"[0-9a-f]{64}", sha256) is None
        )
        if invalid_identity or invalid_shape:
            return self._file_transfer_result(
                ok=False,
                transfer_id=transfer_id,
                file_id=file_id,
                chunk_index=chunk_index,
                reason="invalid_file_transfer_metadata",
            )

        encoded_data = packet.get("data")
        if (
            not isinstance(encoded_data, str)
            or len(encoded_data) % 2 != 0
            or len(encoded_data) > FILE_TRANSFER_MAX_CHUNK_BYTES * 2
            or re.fullmatch(r"[0-9a-fA-F]+", encoded_data) is None
        ):
            return self._file_transfer_result(
                ok=False,
                transfer_id=transfer_id,
                file_id=file_id,
                chunk_index=chunk_index,
                reason="invalid_file_chunk",
            )

        try:
            chunk_data = bytes.fromhex(encoded_data)
        except ValueError:
            chunk_data = b""

        expected_chunk_size = min(
            chunk_size,
            size_bytes - (chunk_index * chunk_size),
        )
        if len(chunk_data) != expected_chunk_size:
            return self._file_transfer_result(
                ok=False,
                transfer_id=transfer_id,
                file_id=file_id,
                chunk_index=chunk_index,
                retryable=True,
                reason="invalid_file_chunk_size",
            )

        metadata = {
            key: value
            for key, value in packet.items()
            if key not in {
                "data",
                "chunk_index",
                "packet_id",
                "protocol_version",
            }
        }
        metadata["source_node"] = source_node
        metadata["destination_node"] = destination_node
        metadata["file_id"] = file_id
        metadata["filename"] = filename
        self.save_group_key_envelopes(packet)
        metadata_json = json.dumps(
            metadata,
            ensure_ascii=False,
            separators=(",", ":"),
        )

        row = self.db.execute(
            """
            SELECT operation_id,
                   source_node,
                   destination_node,
                   file_id,
                   total_chunks,
                   chunk_size,
                   size_bytes,
                   sha256,
                   metadata_json,
                   status,
                   storage_path
            FROM file_transfer_sessions
            WHERE account_login=? AND transfer_id=?
            """,
            (account_login, transfer_id),
        ).fetchone()

        if row:
            consistent = (
                row[0] == operation_id
                and row[1] == source_node
                and row[2] == destination_node
                and row[3] == file_id
                and int(row[4]) == total_chunks
                and int(row[5]) == chunk_size
                and int(row[6]) == size_bytes
                and row[7] == sha256
            )
            if not consistent:
                return self._file_transfer_result(
                    ok=False,
                    transfer_id=transfer_id,
                    file_id=file_id,
                    chunk_index=chunk_index,
                    reason="file_transfer_metadata_mismatch",
                )
            if row[9] == "complete":
                try:
                    stored_metadata = json.loads(row[8] or "{}")
                except (TypeError, ValueError, json.JSONDecodeError):
                    stored_metadata = metadata
                return self._file_transfer_result(
                    ok=True,
                    transfer_id=transfer_id,
                    file_id=file_id,
                    chunk_index=chunk_index,
                    received_indexes=range(total_chunks),
                    complete=True,
                    metadata=stored_metadata,
                    storage_path=row[10],
                    sha256=sha256,
                    size_bytes=size_bytes,
                )
        else:
            self.db.execute(
                """
                INSERT INTO file_transfer_sessions(
                    account_login,
                    transfer_id,
                    operation_id,
                    source_node,
                    destination_node,
                    file_id,
                    total_chunks,
                    chunk_size,
                    size_bytes,
                    sha256,
                    metadata_json,
                    status,
                    created_at,
                    updated_at
                )
                VALUES(?,?,?,?,?,?,?,?,?,?,?,'receiving',
                       CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)
                """,
                (
                    account_login,
                    transfer_id,
                    operation_id,
                    source_node,
                    destination_node,
                    file_id,
                    total_chunks,
                    chunk_size,
                    size_bytes,
                    sha256,
                    metadata_json,
                ),
            )

        pending_path = self._file_transfer_pending_path(
            account_login,
            transfer_id,
        )
        chunk_path = pending_path / f"{chunk_index:08d}.part"
        chunk_sha256 = hashlib.sha256(chunk_data).hexdigest()
        existing_chunk = self.db.execute(
            """
            SELECT size_bytes, sha256, chunk_path
            FROM file_transfer_chunks
            WHERE account_login=?
              AND transfer_id=?
              AND chunk_index=?
            """,
            (account_login, transfer_id, chunk_index),
        ).fetchone()
        if not (
            existing_chunk
            and int(existing_chunk[0]) == len(chunk_data)
            and existing_chunk[1] == chunk_sha256
            and os.path.isfile(existing_chunk[2])
        ):
            self._atomic_write_bytes(chunk_path, chunk_data)
            self.db.execute(
                """
                INSERT INTO file_transfer_chunks(
                    account_login,
                    transfer_id,
                    chunk_index,
                    size_bytes,
                    sha256,
                    chunk_path,
                    created_at
                )
                VALUES(?,?,?,?,?,?,CURRENT_TIMESTAMP)
                ON CONFLICT(account_login, transfer_id, chunk_index)
                DO UPDATE SET
                    size_bytes=excluded.size_bytes,
                    sha256=excluded.sha256,
                    chunk_path=excluded.chunk_path,
                    created_at=CURRENT_TIMESTAMP
                """,
                (
                    account_login,
                    transfer_id,
                    chunk_index,
                    len(chunk_data),
                    chunk_sha256,
                    str(chunk_path),
                ),
            )

        self.db.execute(
            """
            UPDATE file_transfer_sessions
            SET updated_at=CURRENT_TIMESTAMP
            WHERE account_login=? AND transfer_id=?
            """,
            (account_login, transfer_id),
        )
        self.db.commit()

        chunk_rows = self.db.execute(
            """
            SELECT chunk_index, chunk_path
            FROM file_transfer_chunks
            WHERE account_login=? AND transfer_id=?
            ORDER BY chunk_index
            """,
            (account_login, transfer_id),
        ).fetchall()
        received_indexes = [int(item[0]) for item in chunk_rows]
        if len(received_indexes) < total_chunks:
            return self._file_transfer_result(
                ok=True,
                transfer_id=transfer_id,
                file_id=file_id,
                chunk_index=chunk_index,
                received_indexes=received_indexes,
                metadata=metadata,
                sha256=sha256,
                size_bytes=size_bytes,
            )

        if received_indexes != list(range(total_chunks)):
            return self._file_transfer_result(
                ok=True,
                transfer_id=transfer_id,
                file_id=file_id,
                chunk_index=chunk_index,
                received_indexes=received_indexes,
                retryable=True,
                reason="file_transfer_has_gaps",
                metadata=metadata,
                sha256=sha256,
                size_bytes=size_bytes,
            )

        completed_key = hashlib.sha256(
            f"{file_id}\0{sha256}".encode("utf-8")
        ).hexdigest()
        completed_path = (
            self._file_transfer_root()
            / "completed"
            / completed_key[:2]
            / f"{completed_key}.bin"
        )
        completed_path.parent.mkdir(parents=True, exist_ok=True)
        assembling_path = completed_path.with_suffix(".assembling")
        digest = hashlib.sha256()
        assembled_size = 0
        missing_indexes = []
        try:
            with assembling_path.open("wb") as output:
                for index, raw_path in chunk_rows:
                    path = str(raw_path or "")
                    if not os.path.isfile(path):
                        missing_indexes.append(int(index))
                        continue
                    with open(path, "rb") as source:
                        while True:
                            block = source.read(1024 * 1024)
                            if not block:
                                break
                            output.write(block)
                            digest.update(block)
                            assembled_size += len(block)
                output.flush()
                os.fsync(output.fileno())
        except OSError:
            try:
                assembling_path.unlink(missing_ok=True)
            except OSError:
                pass
            return self._file_transfer_result(
                ok=False,
                transfer_id=transfer_id,
                file_id=file_id,
                chunk_index=chunk_index,
                received_indexes=received_indexes,
                retryable=True,
                reason="file_transfer_storage_error",
            )

        if missing_indexes:
            assembling_path.unlink(missing_ok=True)
            self.db.executemany(
                """
                DELETE FROM file_transfer_chunks
                WHERE account_login=?
                  AND transfer_id=?
                  AND chunk_index=?
                """,
                [
                    (account_login, transfer_id, index)
                    for index in missing_indexes
                ],
            )
            self.db.commit()
            received_indexes = [
                index
                for index in received_indexes
                if index not in set(missing_indexes)
            ]
            return self._file_transfer_result(
                ok=False,
                transfer_id=transfer_id,
                file_id=file_id,
                chunk_index=chunk_index,
                received_indexes=received_indexes,
                retryable=True,
                reason="file_transfer_chunk_missing",
            )

        if assembled_size != size_bytes or digest.hexdigest() != sha256:
            assembling_path.unlink(missing_ok=True)
            self.db.execute(
                """
                DELETE FROM file_transfer_chunks
                WHERE account_login=? AND transfer_id=?
                """,
                (account_login, transfer_id),
            )
            self.db.execute(
                """
                UPDATE file_transfer_sessions
                SET updated_at=CURRENT_TIMESTAMP,
                    status='receiving',
                    storage_path=''
                WHERE account_login=? AND transfer_id=?
                """,
                (account_login, transfer_id),
            )
            self.db.commit()
            shutil.rmtree(pending_path, ignore_errors=True)
            return self._file_transfer_result(
                ok=False,
                transfer_id=transfer_id,
                file_id=file_id,
                chunk_index=chunk_index,
                retryable=True,
                reset=True,
                reason="file_checksum_mismatch",
            )

        os.replace(assembling_path, completed_path)
        sender_login = self.get_login_by_node(source_node)
        receiver_login = self.get_login_by_node(destination_node)
        self.db.execute(
            """
            INSERT OR IGNORE INTO server_files(
                file_id,
                sender_node,
                sender_login,
                sender_name,
                receiver_node,
                receiver_login,
                group_id,
                group_name,
                is_channel,
                comments_enabled,
                filename,
                caption,
                reply_to_message_id,
                reply_to_text,
                is_channel_comment,
                data,
                group_key_id,
                message_kind,
                chat_kind,
                chat_id,
                message_effect,
                storage_path,
                sha256,
                size_bytes,
                created_at
            )
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'',?,?,?,?,?,?,?,?,
                   STRFTIME('%Y-%m-%d %H:%M:%f','now'))
            """,
            (
                file_id,
                source_node,
                sender_login,
                metadata.get("sender") or source_node,
                destination_node,
                receiver_login,
                metadata.get("group_id"),
                metadata.get("group_name") or "",
                1 if metadata.get("is_channel") is True else 0,
                0 if metadata.get("comments_enabled") is False else 1,
                filename,
                metadata.get("caption") or "",
                metadata.get("reply_to_message_id") or "",
                metadata.get("reply_to_text") or "",
                1 if metadata.get("is_channel_comment") is True else 0,
                metadata.get("group_key_id"),
                metadata.get("message_kind") or metadata.get("kind") or "file",
                metadata.get("chat_kind") or "normal",
                metadata.get("chat_id") or "",
                metadata.get("message_effect") or "none",
                str(completed_path),
                sha256,
                size_bytes,
            ),
        )
        existing_file = self.db.execute(
            """
            SELECT COALESCE(sha256, ''), COALESCE(storage_path, '')
            FROM server_files
            WHERE file_id=?
            """,
            (file_id,),
        ).fetchone()
        if existing_file and existing_file[0] not in {"", sha256}:
            self.db.rollback()
            completed_path.unlink(missing_ok=True)
            return self._file_transfer_result(
                ok=False,
                transfer_id=transfer_id,
                file_id=file_id,
                chunk_index=chunk_index,
                reason="file_id_conflict",
            )
        if existing_file and not existing_file[0]:
            self.db.execute(
                """
                UPDATE server_files
                SET storage_path=?, sha256=?, size_bytes=?, data=''
                WHERE file_id=?
                """,
                (str(completed_path), sha256, size_bytes, file_id),
            )

        self.db.execute(
            """
            UPDATE file_transfer_sessions
            SET status='complete',
                storage_path=?,
                updated_at=CURRENT_TIMESTAMP
            WHERE account_login=? AND transfer_id=?
            """,
            (str(completed_path), account_login, transfer_id),
        )
        self.db.execute(
            """
            DELETE FROM file_transfer_chunks
            WHERE account_login=? AND transfer_id=?
            """,
            (account_login, transfer_id),
        )
        self.db.commit()
        shutil.rmtree(pending_path, ignore_errors=True)

        return self._file_transfer_result(
            ok=True,
            transfer_id=transfer_id,
            file_id=file_id,
            chunk_index=chunk_index,
            received_indexes=range(total_chunks),
            complete=True,
            newly_completed=True,
            metadata=metadata,
            storage_path=str(completed_path),
            sha256=sha256,
            size_bytes=size_bytes,
        )

    def cancel_file_transfer(self, account_login, transfer_id):

        account_login = str(account_login or "").strip().lower()
        transfer_id = str(transfer_id or "").strip()
        if not account_login or not transfer_id:
            return False
        row = self.db.execute(
            """
            SELECT status
            FROM file_transfer_sessions
            WHERE account_login=? AND transfer_id=?
            """,
            (account_login, transfer_id),
        ).fetchone()
        if not row:
            return False
        if row[0] == "complete":
            return True
        self.db.execute(
            """
            DELETE FROM file_transfer_chunks
            WHERE account_login=? AND transfer_id=?
            """,
            (account_login, transfer_id),
        )
        self.db.execute(
            """
            DELETE FROM file_transfer_sessions
            WHERE account_login=? AND transfer_id=?
            """,
            (account_login, transfer_id),
        )
        self.db.commit()
        shutil.rmtree(
            self._file_transfer_pending_path(account_login, transfer_id),
            ignore_errors=True,
        )
        return True

    def iter_file_transfer_delivery_packets(
        self,
        transfer_result,
        chunk_size=64 * 1024,
    ):

        metadata = dict(transfer_result.get("metadata") or {})
        storage_path = str(transfer_result.get("storage_path") or "")
        size_bytes = int(transfer_result.get("size_bytes") or 0)
        if not storage_path or not os.path.isfile(storage_path) or size_bytes < 1:
            return
        total_chunks = max(1, (size_bytes + chunk_size - 1) // chunk_size)
        with open(storage_path, "rb") as source:
            for chunk_index in range(total_chunks):
                data = source.read(chunk_size)
                if not data:
                    break
                yield {
                    **metadata,
                    "type": "file_chunk",
                    "packet_id": (
                        f"{transfer_result.get('transfer_id')}:"
                        f"delivery:{chunk_index}"
                    ),
                    "file_transfer_v2": True,
                    "transfer_id": transfer_result.get("transfer_id"),
                    "file_sha256": transfer_result.get("sha256") or "",
                    "file_size": size_bytes,
                    "chunk_size_bytes": chunk_size,
                    "chunk_index": chunk_index,
                    "total_chunks": total_chunks,
                    "data": data.hex(),
                }

    def _delete_server_files(self, where_clause, parameters):

        rows = self.db.execute(
            f"""
            SELECT file_id, COALESCE(storage_path, '')
            FROM server_files
            WHERE {where_clause}
            """,
            parameters,
        ).fetchall()
        if not rows:
            return 0
        file_ids = [row[0] for row in rows if row[0]]
        placeholders = ",".join("?" for _ in file_ids)
        transfer_rows = []
        if file_ids:
            transfer_rows = self.db.execute(
                f"""
                SELECT account_login, transfer_id
                FROM file_transfer_sessions
                WHERE file_id IN ({placeholders})
                """,
                file_ids,
            ).fetchall()
            self.db.execute(
                f"""
                DELETE FROM file_transfer_chunks
                WHERE (account_login, transfer_id) IN (
                    SELECT account_login, transfer_id
                    FROM file_transfer_sessions
                    WHERE file_id IN ({placeholders})
                )
                """,
                file_ids,
            )
            self.db.execute(
                f"""
                DELETE FROM file_transfer_sessions
                WHERE file_id IN ({placeholders})
                """,
                file_ids,
            )
        cursor = self.db.execute(
            f"DELETE FROM server_files WHERE {where_clause}",
            parameters,
        )
        for account_login, transfer_id in transfer_rows:
            shutil.rmtree(
                self._file_transfer_pending_path(account_login, transfer_id),
                ignore_errors=True,
            )
        for _, storage_path in rows:
            if not storage_path:
                continue
            still_used = self.db.execute(
                "SELECT 1 FROM server_files WHERE storage_path=? LIMIT 1",
                (storage_path,),
            ).fetchone()
            if still_used:
                continue
            try:
                os.remove(storage_path)
            except FileNotFoundError:
                pass
            except OSError as error:
                print("File payload cleanup failed:", storage_path, error)
        return max(cursor.rowcount, 0)

    def save_history_packet(
        self,
        packet
    ):

        packet_type = packet.get("type")

        self.save_group_key_envelopes(
            packet
        )

        if packet_type == "chat_message":

            message_id = packet.get("packet_id")

            if not message_id:
                return

            sender_node = packet.get("source_node")
            receiver_node = packet.get("destination_node")

            self.db.execute(
                """
                INSERT OR IGNORE INTO direct_messages(
                    message_id,
                    sender_node,
                    sender_login,
                    sender_name,
                    receiver_node,
                    receiver_login,
                    message,
                    reply_to_message_id,
                    reply_to_text,
                    chat_kind,
                    chat_id,
                    message_effect,
                    created_at
                )
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,STRFTIME(
                    '%Y-%m-%d %H:%M:%f',
                    'now'
                ))
                """,
                (
                    message_id,
                    sender_node,
                    self.get_login_by_node(sender_node),
                    packet.get("sender") or sender_node,
                    receiver_node,
                    self.get_login_by_node(receiver_node),
                    packet.get("message") or "",
                    packet.get("reply_to_message_id"),
                    packet.get("reply_to_text"),
                    packet.get("chat_kind") or "normal",
                    packet.get("chat_id") or "",
                    packet.get("message_effect") or "none"
                )
            )

            self._commit_storage()

        elif packet_type == "profile_update":

            self.save_account_profile(
                packet.get("login"),
                packet.get("source_node"),
                packet.get("display_name"),
                packet.get("public_username"),
                packet.get("about"),
                packet.get("avatar_data"),
                packet.get("encryption_public_key"),
                packet.get("profile_background"),
                packet.get("profile_effect"),
                packet.get("profile_blink_shape"),
                packet.get("avatar_decoration"),
                packet.get("profile_glow"),
                packet.get("profile_accent"),
                packet.get("emoji_status")
            )

        elif packet_type == "sticker_library_update":

            source_login = (
                self.get_login_by_node(packet.get("source_node"))
                or ""
            ).strip().lower()
            requested_login = (
                packet.get("login")
                or ""
            ).strip().lower()
            if (
                source_login
                and requested_login
                and source_login != requested_login
            ):
                return False
            login = source_login or requested_login
            library = packet.get("sticker_library")

            if not login or not isinstance(library, dict):
                return False

            self.db.execute(
                """
                INSERT INTO server_sticker_libraries(
                    login,
                    library_json,
                    updated_at
                )
                VALUES(?,?,STRFTIME('%Y-%m-%d %H:%M:%f','now'))
                ON CONFLICT(login) DO UPDATE SET
                    library_json=excluded.library_json,
                    updated_at=excluded.updated_at
                """,
                (
                    login,
                    json.dumps(library, ensure_ascii=False)
                )
            )

            self._commit_storage()
            return True

        elif packet_type == "story_update":

            story = packet.get("story")
            if not isinstance(story, dict):
                return

            story_id = story.get("id") or packet.get("packet_id")
            owner_node = story.get("owner_node") or packet.get("source_node")
            destination_node = packet.get("destination_node")

            if not story_id or not owner_node:
                return

            cursor = self.db.cursor()
            cursor.execute(
                """
                SELECT recipients_json
                FROM server_stories
                WHERE story_id=?
                """,
                (
                    story_id,
                )
            )
            row = cursor.fetchone()
            recipients = set()
            if row:
                try:
                    recipients.update(json.loads(row[0] or "[]"))
                except json.JSONDecodeError:
                    pass

            owner_login = (
                self.get_login_by_node(owner_node)
                or story.get("owner_login")
                or ""
            ).strip().lower()
            if not row:
                story_limit = int(
                    self.subscription_status(owner_login)
                    .get("entitlements", {})
                    .get("limits", {})
                    .get("story_parallel_items", 3)
                    or 3
                )
                active_count = self.db.execute(
                    """
                    SELECT COUNT(*)
                    FROM server_stories
                    WHERE owner_login=?
                      AND DATETIME(created_at) >= DATETIME('now', '-1 day')
                    """,
                    (owner_login,)
                ).fetchone()[0]
                if active_count >= story_limit:
                    return False

            video_seconds = int(story.get("video_duration_seconds") or 0)
            video_limit = int(
                self.subscription_status(owner_login)
                .get("entitlements", {})
                .get("limits", {})
                .get("story_video_seconds", 30)
                or 30
            )
            if video_seconds > video_limit:
                return False
            if (
                story.get("hd") is True
                and not self.subscription_feature_enabled(
                    owner_login,
                    "story_hd"
                )
            ):
                story["hd"] = False
            if destination_node and destination_node != "SERVER":
                recipients.add(destination_node)
            recipients.add(owner_node)

            self.db.execute(
                """
                INSERT INTO server_stories(
                    story_id,
                    owner_node,
                    owner_login,
                    story_json,
                    recipients_json,
                    created_at
                )
                VALUES(?,?,?,?,?,STRFTIME('%Y-%m-%d %H:%M:%f','now'))
                ON CONFLICT(story_id) DO UPDATE SET
                    story_json=excluded.story_json,
                    recipients_json=excluded.recipients_json
                """,
                (
                    story_id,
                    owner_node,
                    owner_login,
                    json.dumps(story, ensure_ascii=False),
                    json.dumps(sorted(recipients), ensure_ascii=False)
                )
            )

            self._commit_storage()

        elif packet_type == "story_reaction":

            story_id = packet.get("story_id")
            reactor_node = packet.get("source_node")
            reaction = packet.get("reaction") or "heart"

            if not story_id or not reactor_node:
                return

            if reaction not in {
                "heart",
                "fire",
                "laugh",
                "wow",
                "sad",
                "clap"
            }:
                return False
            reactor_login = self.get_login_by_node(reactor_node) or ""
            if (
                reaction != "heart"
                and not self.subscription_feature_enabled(
                    reactor_login,
                    "story_extra_reactions"
                )
            ):
                return False

            if packet.get("replace_existing") is True:
                self.db.execute(
                    """
                    DELETE FROM server_story_reactions
                    WHERE story_id=?
                      AND reactor_node=?
                    """,
                    (
                        story_id,
                        reactor_node
                    )
                )

            if packet.get("liked") is False:
                self.db.execute(
                    """
                    DELETE FROM server_story_reactions
                    WHERE story_id=?
                      AND reactor_node=?
                      AND reaction=?
                    """,
                    (
                        story_id,
                        reactor_node,
                        reaction
                    )
                )
            else:
                self.db.execute(
                    """
                    INSERT INTO server_story_reactions(
                        story_id,
                        reactor_node,
                        reactor_login,
                        reaction,
                        liked,
                        created_at
                    )
                    VALUES(?,?,?,?,1,CURRENT_TIMESTAMP)
                    ON CONFLICT(story_id, reactor_node, reaction)
                    DO UPDATE SET
                        liked=1,
                        created_at=CURRENT_TIMESTAMP
                    """,
                    (
                        story_id,
                        reactor_node,
                        reactor_login,
                        reaction
                    )
                )

            self._commit_storage()

        elif packet_type == "story_view":

            story_id = packet.get("story_id")
            viewer_node = packet.get("source_node")

            if not story_id or not viewer_node:
                return

            self.db.execute(
                """
                INSERT INTO server_story_views(
                    story_id,
                    viewer_node,
                    viewer_login,
                    viewed_at
                )
                VALUES(?,?,?,CURRENT_TIMESTAMP)
                ON CONFLICT(story_id, viewer_node)
                DO UPDATE SET
                    viewed_at=CURRENT_TIMESTAMP
                """,
                (
                    story_id,
                    viewer_node,
                    self.get_login_by_node(viewer_node)
                )
            )

            self._commit_storage()

        elif packet_type == "story_delete":

            story_id = packet.get("story_id")
            owner_node = packet.get("source_node")

            if not story_id or not owner_node:
                return

            cursor = self.db.cursor()
            cursor.execute(
                """
                SELECT owner_node
                FROM server_stories
                WHERE story_id=?
                """,
                (
                    story_id,
                )
            )
            row = cursor.fetchone()
            if row and not self._same_account_nodes(row[0], owner_node):
                return

            self.db.execute(
                "DELETE FROM server_stories WHERE story_id=?",
                (
                    story_id,
                )
            )
            self.db.execute(
                "DELETE FROM server_story_reactions WHERE story_id=?",
                (
                    story_id,
                )
            )
            self.db.execute(
                "DELETE FROM server_story_views WHERE story_id=?",
                (
                    story_id,
                )
            )

            self._commit_storage()

        elif packet_type == "message_edit":

            message_id = packet.get(
                "message_id"
            )

            message = packet.get(
                "message"
            )

            file_caption = packet.get(
                "file_caption"
            )

            sender_node = packet.get(
                "source_node"
            )

            if not message_id or message is None:
                return

            sender_login = self.get_login_by_node(sender_node) or ""

            self.db.execute(
                """
                UPDATE direct_messages
                SET message=?
                WHERE message_id=?
                AND (
                    sender_node=?
                    OR (sender_login!='' AND sender_login=?)
                )
                """,
                (
                    file_caption if file_caption is not None else message,
                    message_id,
                    sender_node,
                    sender_login
                )
            )

            self.db.execute(
                """
                UPDATE server_files
                SET caption=?
                WHERE file_id=?
                AND (
                    sender_node=?
                    OR (sender_login!='' AND sender_login=?)
                )
                """,
                (
                    message,
                    message_id,
                    sender_node,
                    sender_login
                )
            )

            self._commit_storage()

        elif packet_type == "message_delete":

            message_id = packet.get(
                "message_id"
            )

            sender_node = packet.get(
                "source_node"
            )

            if not message_id:
                return

            sender_login = self.get_login_by_node(sender_node) or ""

            self.db.execute(
                """
                DELETE FROM direct_messages
                WHERE message_id=?
                AND (
                    sender_node=?
                    OR (sender_login!='' AND sender_login=?)
                )
                """,
                (
                    message_id,
                    sender_node,
                    sender_login
                )
            )

            self.db.execute(
                """
                DELETE FROM server_reactions
                WHERE scope='direct'
                AND message_id=?
                """,
                (
                    message_id,
                )
            )

            self._delete_server_files(
                """
                file_id=?
                AND (
                    sender_node=?
                    OR (sender_login!='' AND sender_login=?)
                )
                """,
                (message_id, sender_node, sender_login),
            )

            self.db.execute(
                """
                DELETE FROM server_pins
                WHERE message_id=?
                """,
                (
                    message_id,
                )
            )

            self._commit_storage()

        elif packet_type == "chat_delete":

            source_node = packet.get("source_node")
            destination_node = packet.get("destination_node")
            chat_node_id = packet.get("chat_node_id") or destination_node
            chat_kind = packet.get("chat_kind") or "normal"
            chat_id = packet.get("chat_id") or ""

            if not source_node or not destination_node:
                return

            for owner_node, peer_node in (
                (source_node, chat_node_id),
                (destination_node, source_node)
            ):

                owner_login = self.get_login_by_node(owner_node) or ""
                peer_login = self.get_login_by_node(peer_node) or ""

                if self._same_account_nodes(owner_node, peer_node):
                    continue
                if (
                    owner_login
                    and peer_login
                    and owner_login.strip().lower() == peer_login.strip().lower()
                ):
                    continue

                self.db.execute(
                    """
                    INSERT OR REPLACE INTO server_chat_deletes(
                        owner_node,
                        peer_node,
                        owner_login,
                        peer_login,
                        chat_kind,
                        chat_id,
                        deleted_at
                    )
                    VALUES(?,?,?,?,?,?,STRFTIME(
                        '%Y-%m-%d %H:%M:%f',
                        'now'
                    ))
                    """,
                    (
                        owner_node,
                        peer_node,
                        owner_login,
                        peer_login,
                        chat_kind,
                        chat_id
                    )
                )

            self._commit_storage()

        elif packet_type in (
            "message_pin",
            "group_pin"
        ):

            message_id = packet.get(
                "message_id"
            )
            source_node = packet.get(
                "source_node"
            )

            if not message_id or not source_node:
                return

            scope = (
                f"group:{packet.get('group_id')}"
                if packet_type == "group_pin"
                else "chat:" + ":".join(
                    sorted(
                        (
                            source_node,
                            packet.get("destination_node") or ""
                        )
                    )
                )
            )

            if packet.get("action") == "unpin":

                self.db.execute(
                    """
                    DELETE FROM server_pins
                    WHERE scope=?
                      AND message_id=?
                    """,
                    (
                        scope,
                        message_id
                    )
                )

            else:

                self.db.execute(
                    """
                    INSERT INTO server_pins(
                        scope,
                        message_id,
                        pinner_node,
                        pinner_login,
                        text,
                        group_key_id,
                        created_at
                    )
                    VALUES(?,?,?,?,?,?,CURRENT_TIMESTAMP)
                    ON CONFLICT(scope, message_id) DO UPDATE SET
                        pinner_node=excluded.pinner_node,
                        pinner_login=excluded.pinner_login,
                        text=excluded.text,
                        group_key_id=excluded.group_key_id,
                        created_at=CURRENT_TIMESTAMP
                    """,
                    (
                        scope,
                        message_id,
                        source_node,
                        self.get_login_by_node(source_node),
                        packet.get("text") or "",
                        packet.get("group_key_id")
                    )
                )

            self._commit_storage()

        elif packet_type == "group_message":

            group_id = packet.get("group_id")
            group_name = packet.get("group_name") or group_id
            members = packet.get("members") or []

            existing_owner, _ = self.get_group_roles(
                group_id
            )

            if not existing_owner:
                claimed_owner = packet.get("owner_node") or packet.get("source_node")

                self.save_group_members(
                    group_id,
                    group_name,
                    members,
                    claimed_owner,
                    packet.get("admins"),
                    packet.get("is_channel") is True,
                    packet.get("comments_enabled"),
                    packet.get("group_about"),
                    packet.get("group_avatar_data")
                )

            message_id = (
                packet.get("group_message_id")
                or packet.get("packet_id")
            )

            if not message_id:
                return

            sender_node = packet.get("source_node")

            self.db.execute(
                """
                INSERT OR IGNORE INTO server_group_messages(
                    message_id,
                    group_id,
                    group_name,
                    sender_node,
                    sender_login,
                    sender_name,
                    message,
                    reply_to_message_id,
                    reply_to_text,
                    members_json,
                    group_key_id,
                    message_effect,
                    is_channel_comment,
                    created_at
                )
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,STRFTIME(
                    '%Y-%m-%d %H:%M:%f',
                    'now'
                ))
                """,
                (
                    message_id,
                    group_id,
                    group_name,
                    sender_node,
                    self.get_login_by_node(sender_node),
                    packet.get("sender") or sender_node,
                    packet.get("message") or "",
                    packet.get("reply_to_message_id"),
                    packet.get("reply_to_text"),
                    json.dumps(members, ensure_ascii=False),
                    packet.get("group_key_id"),
                    packet.get("message_effect") or "none",
                    1
                    if (
                        packet.get("is_channel_comment") is True
                        or bool(packet.get("reply_to_message_id"))
                    )
                    else 0
                )
            )

            self._commit_storage()

        elif packet_type == "group_update":

            self.save_group_members(
                packet.get("group_id"),
                packet.get("group_name"),
                packet.get("members") or [],
                packet.get("owner_node"),
                packet.get("admins"),
                packet.get("is_channel") is True,
                packet.get("comments_enabled"),
                packet.get("group_about"),
                packet.get("group_avatar_data")
            )

        elif packet_type == "group_member_leave":

            group_id = packet.get("group_id")
            leaver_node = (
                packet.get("leaver_node")
                or packet.get("source_node")
            )

            if not group_id or not leaver_node:
                return

            row = self.db.execute(
                """
                SELECT group_name,
                       group_about,
                       group_avatar_data,
                       members_json,
                       owner_node,
                       admins_json,
                       is_channel,
                       COALESCE(comments_enabled, 1)
                FROM server_groups
                WHERE group_id=?
                """,
                (
                    group_id,
                )
            ).fetchone()

            if not row:
                return

            try:
                members = json.loads(row[3] or "[]")
            except (TypeError, ValueError):
                members = []

            try:
                admins = json.loads(row[5] or "[]")
            except (TypeError, ValueError):
                admins = []

            members = [
                member
                for member in members
                if not self._same_account_nodes(member, leaver_node)
            ]
            admins = [
                admin
                for admin in admins
                if not self._same_account_nodes(admin, leaver_node)
            ]

            self.save_group_members(
                group_id,
                row[0],
                members,
                row[4],
                admins,
                row[6] == 1,
                row[7] == 1,
                row[1],
                row[2]
            )

        elif packet_type == "group_delete":

            group_id = packet.get(
                "group_id"
            )

            if not group_id:
                return

            self.db.execute(
                """
                DELETE FROM server_reactions
                WHERE scope=?
                """,
                (
                    f"group:{group_id}",
                )
            )

            self._delete_server_files(
                "group_id=?",
                (group_id,),
            )

            self.db.execute(
                """
                DELETE FROM server_group_messages
                WHERE group_id=?
                """,
                (
                    group_id,
                )
            )

            self.db.execute(
                """
                DELETE FROM server_group_members
                WHERE group_id=?
                """,
                (
                    group_id,
                )
            )

            self.db.execute(
                """
                DELETE FROM server_group_keys
                WHERE group_id=?
                """,
                (
                    group_id,
                )
            )

            self.db.execute(
                """
                DELETE FROM server_pins
                WHERE scope=?
                """,
                (
                    f"group:{group_id}",
                )
            )

            self.db.execute(
                """
                DELETE FROM server_groups
                WHERE group_id=?
                """,
                (
                    group_id,
                )
            )

            self._commit_storage()

        elif packet_type == "group_message_edit":

            message_id = packet.get(
                "group_message_id"
            )

            message = packet.get(
                "message"
            )

            sender_node = packet.get(
                "source_node"
            )

            if not message_id or message is None:
                return

            sender_login = self.get_login_by_node(sender_node) or ""

            self.db.execute(
                """
                UPDATE server_group_messages
                SET message=?,
                    group_key_id=COALESCE(?, group_key_id)
                WHERE message_id=?
                AND (
                    sender_node=?
                    OR (sender_login!='' AND sender_login=?)
                )
                """,
                (
                    message,
                    packet.get("group_key_id"),
                    message_id,
                    sender_node,
                    sender_login
                )
            )

            self.db.execute(
                """
                UPDATE server_files
                SET caption=?,
                    group_key_id=COALESCE(?, group_key_id)
                WHERE file_id=?
                AND (
                    sender_node=?
                    OR (sender_login!='' AND sender_login=?)
                )
                """,
                (
                    message,
                    packet.get("group_key_id"),
                    message_id,
                    sender_node,
                    sender_login
                )
            )

            self._commit_storage()

        elif packet_type == "group_message_delete":

            message_id = packet.get(
                "group_message_id"
            )

            sender_node = packet.get(
                "source_node"
            )

            if not message_id:
                return

            sender_login = self.get_login_by_node(sender_node) or ""

            self.db.execute(
                """
                DELETE FROM server_group_messages
                WHERE message_id=?
                AND (
                    sender_node=?
                    OR (sender_login!='' AND sender_login=?)
                )
                """,
                (
                    message_id,
                    sender_node,
                    sender_login
                )
            )

            self.db.execute(
                """
                DELETE FROM server_reactions
                WHERE message_id=?
                """,
                (
                    message_id,
                )
            )

            self._delete_server_files(
                """
                file_id=?
                AND (
                    sender_node=?
                    OR (sender_login!='' AND sender_login=?)
                )
                """,
                (message_id, sender_node, sender_login),
            )

            self.db.execute(
                """
                DELETE FROM server_pins
                WHERE message_id=?
                """,
                (
                    message_id,
                )
            )

            self._commit_storage()

        elif packet_type in ("message_reaction", "group_reaction"):

            scope = (
                f"group:{packet.get('group_id')}"
                if packet_type == "group_reaction"
                else "direct"
            )

            message_id = (
                packet.get("group_message_id")
                or packet.get("message_id")
            )

            reactor_node = packet.get("source_node")
            reaction = packet.get("reaction")

            if not message_id or not reactor_node or not reaction:
                return

            reactor_login = (
                self.get_login_by_node(reactor_node) or ""
            ).strip().lower()
            reactor_identity = (
                f"login:{reactor_login}"
                if reactor_login
                else f"node:{reactor_node}"
            )
            packet["reactor_login"] = reactor_login
            packet["reactor_identity"] = reactor_identity

            cursor = self.db.execute(
                """
                INSERT OR IGNORE INTO server_reactions(
                    scope,
                    message_id,
                    reactor_node,
                    reactor_login,
                    reactor_identity,
                    reaction
                )
                VALUES(?,?,?,?,?,?)
                """,
                (
                    scope,
                    message_id,
                    reactor_node,
                    reactor_login,
                    reactor_identity,
                    reaction
                )
            )

            self._commit_storage()
            return True if cursor.rowcount > 0 else "duplicate"

        elif packet_type == "file_chunk":

            file_id = packet.get("file_id")
            filename = packet.get("filename")
            chunk_index = packet.get("chunk_index")
            total_chunks = packet.get("total_chunks")
            data = packet.get("data")

            if (
                not file_id
                or not filename
                or chunk_index is None
                or not total_chunks
                or data is None
            ):
                return

            if file_id not in self.file_chunks:

                self.file_chunks[
                    file_id
                ] = {
                    "packet": packet,
                    "total_chunks": total_chunks,
                    "chunks": {}
                }

            self.file_chunks[
                file_id
            ][
                "chunks"
            ][
                chunk_index
            ] = data

            info = self.file_chunks[
                file_id
            ]

            if len(info["chunks"]) != info["total_chunks"]:
                return "pending"

            full_data = "".join(
                info["chunks"][i]
                for i in range(
                    info["total_chunks"]
                )
            )

            first_packet = info["packet"]
            sender_node = first_packet.get("source_node")
            receiver_node = first_packet.get("destination_node")

            insert_cursor = self.db.execute(
                """
                INSERT OR IGNORE INTO server_files(
                    file_id,
                    sender_node,
                    sender_login,
                    sender_name,
                    receiver_node,
                    receiver_login,
                    group_id,
                    group_name,
                    is_channel,
                    comments_enabled,
                    filename,
                    caption,
                    reply_to_message_id,
                    reply_to_text,
                    is_channel_comment,
                    data,
                    group_key_id,
                    message_kind,
                    chat_kind,
                    chat_id,
                    message_effect,
                    created_at
                )
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,STRFTIME(
                    '%Y-%m-%d %H:%M:%f',
                    'now'
                ))
                """,
                (
                    file_id,
                    sender_node,
                    self.get_login_by_node(sender_node),
                    first_packet.get("sender") or sender_node,
                    receiver_node,
                    self.get_login_by_node(receiver_node),
                    first_packet.get("group_id"),
                    first_packet.get("group_name") or "",
                    1 if first_packet.get("is_channel") is True else 0,
                    0 if first_packet.get("comments_enabled") is False else 1,
                    filename,
                    first_packet.get("caption") or "",
                    first_packet.get("reply_to_message_id") or "",
                    first_packet.get("reply_to_text") or "",
                    1 if first_packet.get("is_channel_comment") is True else 0,
                    full_data,
                    first_packet.get("group_key_id"),
                    first_packet.get("message_kind") or first_packet.get("kind") or "file",
                    first_packet.get("chat_kind") or "normal",
                    first_packet.get("chat_id") or "",
                    first_packet.get("message_effect") or "none"
                )
            )

            self._commit_storage()

            del self.file_chunks[file_id]
            return True if insert_cursor.rowcount > 0 else "duplicate"

    def save_group_key_envelopes(
        self,
        packet
    ):

        group_id = packet.get("group_id")
        key_id = packet.get("group_key_id")

        if not group_id or not key_id:
            return

        if (
            packet.get("type") == "file_chunk"
            and packet.get("chunk_index") != 0
        ):
            return

        for member_node, envelope in (
            (
                packet.get("destination_node"),
                packet.get("group_key_envelope")
            ),
            (
                packet.get("source_node"),
                packet.get("group_key_sender_envelope")
            )
        ):

            if not member_node or not envelope:
                continue

            self.db.execute(
                """
                INSERT INTO server_group_keys(
                    group_id,
                    key_id,
                    member_node,
                    member_login,
                    key_envelope
                )
                VALUES(?,?,?,?,?)
                ON CONFLICT(group_id, key_id, member_node)
                DO UPDATE SET
                    member_login=excluded.member_login,
                    key_envelope=excluded.key_envelope
                """,
                (
                    group_id,
                    key_id,
                    member_node,
                    self.get_login_by_node(member_node),
                    envelope
                )
            )

        self._commit_storage()

    def mutation_was_processed(self, account_login, outbox_id):

        normalized_login = str(account_login or "").strip().lower()
        normalized_outbox_id = str(outbox_id or "").strip()
        if not normalized_login or not normalized_outbox_id:
            return False

        row = self.db.execute(
            """
            SELECT 1
            FROM processed_mutations
            WHERE account_login=? AND outbox_id=?
            LIMIT 1
            """,
            (
                normalized_login,
                normalized_outbox_id,
            )
        ).fetchone()
        return row is not None

    def mark_mutation_processed(
        self,
        account_login,
        outbox_id,
        operation_id="",
        packet_type="",
        packet_id=""
    ):

        normalized_login = str(account_login or "").strip().lower()
        normalized_outbox_id = str(outbox_id or "").strip()
        if not normalized_login or not normalized_outbox_id:
            return False

        cursor = self.db.execute(
            """
            INSERT OR IGNORE INTO processed_mutations(
                account_login,
                outbox_id,
                operation_id,
                packet_type,
                packet_id
            )
            VALUES(?,?,?,?,?)
            """,
            (
                normalized_login,
                normalized_outbox_id,
                str(operation_id or "").strip(),
                str(packet_type or "").strip(),
                str(packet_id or "").strip(),
            )
        )
        self._commit_storage()
        return cursor.rowcount > 0

    def save_offline_packet(
        self,
        destination_node,
        packet
    ):

        destination = str(destination_node or "").strip()
        packet_type = (
            str(packet.get("type") or "")
            if isinstance(packet, dict)
            else ""
        )

        if (
            not destination
            or destination.upper() == "SERVER"
            or packet_type not in OFFLINE_QUEUE_PACKET_TYPES
        ):
            return False

        self.db.execute(
            """
            DELETE FROM offline_packets
            WHERE created_at < DATETIME('now', ?)
            """,
            (
                f"-{OFFLINE_PACKET_MAX_AGE_DAYS} days",
            )
        )

        self.db.execute(
            """
            INSERT INTO offline_packets(
                destination_node,
                packet_json
            )
            VALUES(?,?)
            """,
            (
                destination,
                json.dumps(
                    packet,
                    ensure_ascii=False
                )
            )
        )

        self.db.commit()

        return True

    async def flush_offline_packets(
        self,
        node_id,
        websocket,
        require_ack=False
    ):

        cursor = self.db.cursor()

        cursor.execute(
            """
            SELECT id,
                   packet_json

            FROM offline_packets

            WHERE destination_node=?

            ORDER BY id
            """,
            (
                node_id,
            )
        )

        rows = cursor.fetchall()

        for packet_id, packet_json in rows:

            if require_ack:
                try:
                    packet = json.loads(packet_json)
                except (TypeError, ValueError, json.JSONDecodeError):
                    packet = None

                if not isinstance(packet, dict):
                    self.db.execute(
                        "DELETE FROM offline_packets WHERE id=?",
                        (packet_id,)
                    )
                    continue

                await websocket.send(
                    json.dumps(
                        {
                            **packet,
                            "_offline_queue_id": packet_id
                        },
                        ensure_ascii=False
                    )
                )
                continue

            await websocket.send(packet_json)

            self.db.execute(
                "DELETE FROM offline_packets WHERE id=?",
                (packet_id,)
            )

        self.db.commit()

    def acknowledge_offline_packet(self, node_id, queue_id):

        try:
            normalized_queue_id = int(queue_id)
        except (TypeError, ValueError):
            return False

        cursor = self.db.execute(
            """
            DELETE FROM offline_packets
            WHERE id=?
              AND destination_node=?
            """,
            (
                normalized_queue_id,
                node_id
            )
        )
        self._commit_storage()
        return cursor.rowcount > 0
