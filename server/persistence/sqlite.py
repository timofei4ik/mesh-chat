import json
from contextlib import nullcontext

from .sqlite_billing import SQLiteBillingRepository


class SQLiteIdentityRepository:
    def __init__(self, connection):
        self._connection = connection

    @staticmethod
    def _login(value):
        return str(value or "").strip().lower()

    @staticmethod
    def _node(value):
        return str(value or "").strip()

    def account_exists(self, login):
        return self._connection.execute(
            "SELECT 1 FROM accounts WHERE login=?",
            (self._login(login),),
        ).fetchone() is not None

    def credentials(self, login):
        return self._connection.execute(
            """
            SELECT password_salt, password_hash
            FROM accounts
            WHERE login=?
            """,
            (self._login(login),),
        ).fetchone()

    def public_username_owner(
        self,
        public_username,
        excluding_login="",
    ):
        row = self._connection.execute(
            """
            SELECT login
            FROM accounts
            WHERE public_username=? AND login!=?
            """,
            (
                str(public_username or "").strip().lower().lstrip("@"),
                self._login(excluding_login),
            ),
        ).fetchone()
        return row[0] if row else None

    def create_account(self, account):
        self._connection.execute(
            """
            INSERT INTO accounts(
                login,
                password_salt,
                password_hash,
                node_id,
                display_name,
                public_username,
                about,
                avatar_data,
                encryption_public_key,
                email,
                email_verified_at,
                last_login
            )
            VALUES(
                ?,?,?,?,?,?,?,?,?,?,
                CASE WHEN ? THEN CURRENT_TIMESTAMP ELSE NULL END,
                CURRENT_TIMESTAMP
            )
            """,
            (
                self._login(account.get("login")),
                account.get("password_salt"),
                account.get("password_hash"),
                self._node(account.get("node_id")),
                account.get("display_name"),
                account.get("public_username"),
                account.get("about"),
                account.get("avatar_data"),
                account.get("encryption_public_key"),
                account.get("email") or "",
                bool(account.get("email_verified")),
            ),
        )

    def record_login(self, login, node_id, encryption_public_key=None):
        self._connection.execute(
            """
            UPDATE accounts
            SET node_id=?,
                encryption_public_key=COALESCE(
                    ?,
                    encryption_public_key
                ),
                last_login=CURRENT_TIMESTAMP
            WHERE login=?
            """,
            (
                self._node(node_id),
                encryption_public_key,
                self._login(login),
            ),
        )

    def encryption_recovery(self, login):
        row = self._connection.execute(
            """
            SELECT encryption_recovery
            FROM accounts
            WHERE login=?
            """,
            (self._login(login),),
        ).fetchone()
        return str(row[0] or "") if row else ""

    def change_credentials(
        self,
        login,
        password_salt,
        password_hash,
        encryption_recovery,
    ):
        normalized_login = self._login(login)
        self._connection.execute(
            """
            UPDATE accounts
            SET password_salt=?,
                password_hash=?,
                encryption_recovery=?,
                last_login=CURRENT_TIMESTAMP
            WHERE login=?
            """,
            (
                password_salt,
                password_hash,
                encryption_recovery,
                normalized_login,
            ),
        )
        self._connection.execute(
            """
            UPDATE service_sessions
            SET revoked_at=CURRENT_TIMESTAMP
            WHERE login=?
            """,
            (normalized_login,),
        )

    def verified_email(self, login):
        row = self._connection.execute(
            """
            SELECT COALESCE(email, ''), email_verified_at
            FROM accounts
            WHERE login=?
            """,
            (self._login(login),),
        ).fetchone()
        return str(row[0] or "") if row and row[1] else ""

    def email_owner(self, email, excluding_login=""):
        row = self._connection.execute(
            """
            SELECT login FROM accounts
            WHERE lower(email)=?
              AND email_verified_at IS NOT NULL
              AND login!=?
            """,
            (
                str(email or "").strip().lower(),
                self._login(excluding_login),
            ),
        ).fetchone()
        return row[0] if row else None

    def is_email_device_trusted(self, login, node_id):
        return self._connection.execute(
            """
            SELECT 1
            FROM account_email_trusted_devices
            WHERE login=? AND node_id=?
            """,
            (self._login(login), self._node(node_id)),
        ).fetchone() is not None

    def trust_email_device(self, login, node_id):
        self._connection.execute(
            """
            INSERT INTO account_email_trusted_devices(
                login,
                node_id,
                verified_at
            )
            VALUES(?,?,CURRENT_TIMESTAMP)
            ON CONFLICT(login, node_id) DO UPDATE SET
                verified_at=CURRENT_TIMESTAMP
            """,
            (self._login(login), self._node(node_id)),
        )

    def bind_email(self, login, email, node_id):
        normalized_login = self._login(login)
        self._connection.execute(
            """
            UPDATE accounts
            SET email=?, email_verified_at=CURRENT_TIMESTAMP
            WHERE login=?
            """,
            (str(email or "").strip().lower(), normalized_login),
        )
        self.trust_email_device(normalized_login, node_id)

    def latest_email_challenge_age(self, login, node_id, purpose):
        row = self._connection.execute(
            """
            SELECT CAST(
                strftime('%s','now') - strftime('%s', created_at)
                AS INTEGER
            )
            FROM email_auth_challenges
            WHERE login=?
              AND node_id=?
              AND purpose=?
              AND consumed_at IS NULL
            ORDER BY created_at DESC
            LIMIT 1
            """,
            (self._login(login), self._node(node_id), purpose),
        ).fetchone()
        return row[0] if row else None

    def create_email_challenge(self, challenge):
        self._connection.execute(
            """
            INSERT INTO email_auth_challenges(
                challenge_id,
                login,
                node_id,
                email,
                purpose,
                code_salt,
                code_hash,
                expires_at
            )
            VALUES(?,?,?,?,?,?,?,datetime('now', ?))
            """,
            (
                challenge.get("challenge_id"),
                self._login(challenge.get("login")),
                self._node(challenge.get("node_id")),
                str(challenge.get("email") or "").strip().lower(),
                challenge.get("purpose"),
                challenge.get("code_salt"),
                challenge.get("code_hash"),
                challenge.get("expires_delta"),
            ),
        )

    def email_challenge(self, challenge_id, purpose):
        row = self._connection.execute(
            """
            SELECT login,
                   node_id,
                   email,
                   code_salt,
                   code_hash,
                   attempts,
                   expires_at > CURRENT_TIMESTAMP,
                   consumed_at
            FROM email_auth_challenges
            WHERE challenge_id=? AND purpose=?
            """,
            (self._node(challenge_id), purpose),
        ).fetchone()
        if not row:
            return None
        return {
            "login": row[0],
            "node_id": row[1],
            "email": row[2],
            "code_salt": row[3],
            "code_hash": row[4],
            "attempts": int(row[5] or 0),
            "active": bool(row[6]) and row[7] is None,
        }

    def discard_email_challenge(self, challenge_id):
        self._connection.execute(
            "DELETE FROM email_auth_challenges WHERE challenge_id=?",
            (self._node(challenge_id),),
        )

    def increment_email_challenge_attempts(self, challenge_id):
        self._connection.execute(
            """
            UPDATE email_auth_challenges
            SET attempts=attempts+1
            WHERE challenge_id=?
            """,
            (self._node(challenge_id),),
        )

    def consume_email_challenge(self, challenge_id):
        self._connection.execute(
            """
            UPDATE email_auth_challenges
            SET consumed_at=CURRENT_TIMESTAMP
            WHERE challenge_id=?
            """,
            (self._node(challenge_id),),
        )

    def save_account_device(self, device):
        self._connection.execute(
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
                self._login(device.get("login")),
                self._node(device.get("node_id")),
                device.get("display_name"),
                device.get("device_name"),
                device.get("app_version"),
                1 if device.get("online", True) else 0,
            ),
        )

    def set_account_device_online(self, login, node_id, online):
        self._connection.execute(
            """
            UPDATE account_devices
            SET online=?, last_seen=CURRENT_TIMESTAMP
            WHERE login=? AND node_id=?
            """,
            (
                1 if online else 0,
                self._login(login),
                self._node(node_id),
            ),
        )

    def get_account_devices(self, login):
        normalized_login = self._login(login)
        if not normalized_login:
            return []

        rows = self._connection.execute(
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
            (normalized_login,),
        ).fetchall()
        return [
            {
                "node_id": row[0],
                "display_name": row[1],
                "device_name": row[2] or "",
                "app_version": row[3],
                "online": bool(row[4]) and not bool(row[5]),
                "revoked": bool(row[5]),
                "last_seen": row[6],
            }
            for row in rows
        ]

    def is_account_device_revoked(self, login, node_id):
        row = self._connection.execute(
            """
            SELECT revoked
            FROM account_devices
            WHERE login=? AND node_id=?
            LIMIT 1
            """,
            (self._login(login), self._node(node_id)),
        ).fetchone()
        return bool(row and row[0])

    def reactivate_account_device(self, login, node_id):
        self._connection.execute(
            """
            UPDATE account_devices
            SET revoked=0, last_seen=CURRENT_TIMESTAMP
            WHERE login=? AND node_id=?
            """,
            (self._login(login), self._node(node_id)),
        )

    def account_device_exists(self, login, node_id):
        return self._connection.execute(
            """
            SELECT 1
            FROM account_devices
            WHERE login=? AND node_id=?
            LIMIT 1
            """,
            (self._login(login), self._node(node_id)),
        ).fetchone() is not None

    def revoke_account_device(self, login, node_id):
        self._connection.execute(
            """
            UPDATE account_devices
            SET revoked=1,
                online=0,
                last_seen=CURRENT_TIMESTAMP
            WHERE login=? AND node_id=?
            """,
            (self._login(login), self._node(node_id)),
        )

    def rename_account_device(self, login, node_id, custom_name):
        self._connection.execute(
            """
            UPDATE account_devices
            SET custom_name=?, last_seen=CURRENT_TIMESTAMP
            WHERE login=? AND node_id=?
            """,
            (
                custom_name or None,
                self._login(login),
                self._node(node_id),
            ),
        )

    def online_account_nodes(self, login):
        return [
            row[0]
            for row in self._connection.execute(
                """
                SELECT node_id
                FROM account_devices
                WHERE login=? AND online=1 AND revoked=0
                ORDER BY last_seen DESC
                """,
                (self._login(login),),
            ).fetchall()
            if row[0]
        ]

    def login_by_node(self, node_id):
        normalized_node = self._node(node_id)
        row = self._connection.execute(
            "SELECT login FROM accounts WHERE node_id=?",
            (normalized_node,),
        ).fetchone()
        if row:
            return row[0]
        row = self._connection.execute(
            "SELECT login FROM account_devices WHERE node_id=?",
            (normalized_node,),
        ).fetchone()
        return row[0] if row else None

    def update_profile(self, login, profile):
        self._connection.execute(
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
                self._node(profile.get("node_id")),
                profile.get("display_name"),
                profile.get("public_username"),
                profile.get("about"),
                profile.get("avatar_data"),
                profile.get("encryption_public_key"),
                profile.get("profile_background"),
                profile.get("profile_effect"),
                profile.get("profile_blink_shape"),
                profile.get("avatar_decoration"),
                profile.get("profile_glow"),
                profile.get("profile_accent"),
                profile.get("emoji_status"),
                self._login(login),
            ),
        )

    @staticmethod
    def _profile_from_row(row):
        if not row:
            return None
        return {
            "login": row[0],
            "node_id": row[1],
            "display_name": row[2],
            "public_username": row[3],
            "about": row[4],
            "avatar_data": row[5],
            "encryption_public_key": row[6],
            "profile_background": row[7],
            "profile_effect": row[8],
            "profile_blink_shape": row[9],
            "avatar_decoration": row[10],
            "profile_glow": bool(row[11]),
            "profile_accent": row[12],
            "emoji_status": row[13] or "",
        }

    def profile_by_public_username(self, public_username):
        row = self._connection.execute(
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
                   COALESCE(a.profile_accent, 4282557941),
                   COALESCE(a.emoji_status, '')
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
                str(public_username or "").strip().lower().lstrip("@"),
            ),
        ).fetchone()
        return self._profile_from_row(row)

    def profile_by_node(self, node_id):
        normalized_node = self._node(node_id)
        row = self._connection.execute(
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
                   COALESCE(a.profile_accent, 4282557941),
                   COALESCE(a.emoji_status, '')
            FROM accounts a
            LEFT JOIN account_devices d
              ON d.login=a.login
            WHERE a.node_id=? OR d.node_id=?
            LIMIT 1
            """,
            (normalized_node, normalized_node, normalized_node),
        ).fetchone()
        return self._profile_from_row(row)


class SQLiteSubscriptionRepository:
    def __init__(self, connection):
        self._connection = connection

    @staticmethod
    def _login(value):
        return str(value or "").strip().lower()

    def subscription(self, login, product):
        return self._connection.execute(
            """
            SELECT plan_code,
                   status,
                   current_period_start,
                   current_period_end,
                   cancel_at_period_end,
                   provider,
                   updated_at
            FROM account_subscriptions
            WHERE login=? AND product=?
            """,
            (self._login(login), product),
        ).fetchone()

    def subscriptions(self, login, products):
        normalized_products = tuple(products)
        if not normalized_products:
            return []
        placeholders = ",".join("?" for _ in normalized_products)
        return self._connection.execute(
            f"""
            SELECT product,
                   plan_code,
                   status,
                   current_period_start,
                   current_period_end,
                   cancel_at_period_end,
                   provider,
                   provider_customer_id,
                   provider_subscription_id,
                   updated_at
            FROM account_subscriptions
            WHERE login=? AND product IN ({placeholders})
            """,
            (self._login(login), *normalized_products),
        ).fetchall()

    def provider_event_exists(self, provider_event_id):
        if not provider_event_id:
            return False
        return self._connection.execute(
            """
            SELECT 1
            FROM subscription_events
            WHERE provider_event_id=?
            """,
            (provider_event_id,),
        ).fetchone() is not None

    def grant(
        self,
        login,
        product,
        plan_code,
        duration_days,
        provider,
        provider_subscription_id,
    ):
        period_modifier = f"+{max(1, int(duration_days))} days"
        self._connection.execute(
            """
            INSERT INTO account_subscriptions(
                login,
                product,
                plan_code,
                status,
                current_period_start,
                current_period_end,
                cancel_at_period_end,
                provider,
                provider_subscription_id,
                updated_at
            )
            VALUES(
                ?, ?, ?, 'active', CURRENT_TIMESTAMP,
                DATETIME('now', ?), 0, ?, ?, CURRENT_TIMESTAMP
            )
            ON CONFLICT(login, product) DO UPDATE SET
                plan_code=excluded.plan_code,
                status='active',
                current_period_start=CASE
                    WHEN account_subscriptions.current_period_end
                         > CURRENT_TIMESTAMP
                    THEN account_subscriptions.current_period_start
                    ELSE CURRENT_TIMESTAMP
                END,
                current_period_end=DATETIME(
                    CASE
                        WHEN account_subscriptions.current_period_end
                             > CURRENT_TIMESTAMP
                        THEN account_subscriptions.current_period_end
                        ELSE CURRENT_TIMESTAMP
                    END,
                    ?
                ),
                cancel_at_period_end=0,
                provider=excluded.provider,
                provider_subscription_id=excluded.provider_subscription_id,
                updated_at=CURRENT_TIMESTAMP
            """,
            (
                self._login(login),
                product,
                plan_code,
                period_modifier,
                provider,
                provider_subscription_id,
                period_modifier,
            ),
        )

    def revoke(self, login, products):
        normalized_products = tuple(products)
        if not normalized_products:
            return
        placeholders = ",".join("?" for _ in normalized_products)
        self._connection.execute(
            f"""
            UPDATE account_subscriptions
            SET status='revoked',
                current_period_end=CURRENT_TIMESTAMP,
                updated_at=CURRENT_TIMESTAMP
            WHERE login=? AND product IN ({placeholders})
            """,
            (self._login(login), *normalized_products),
        )

    def set_provider_lease(
        self,
        login,
        product,
        provider,
        provider_subscription_id,
        lease_hours,
    ):
        lease_modifier = f"+{max(1, int(lease_hours))} hours"
        self._connection.execute(
            """
            INSERT INTO account_subscriptions(
                login,
                product,
                plan_code,
                status,
                current_period_start,
                current_period_end,
                cancel_at_period_end,
                provider,
                provider_subscription_id,
                updated_at
            )
            VALUES(
                ?, ?, 'meshpro', 'active', CURRENT_TIMESTAMP,
                DATETIME('now', ?), 0, ?, ?, CURRENT_TIMESTAMP
            )
            ON CONFLICT(login, product) DO UPDATE SET
                plan_code='meshpro',
                status='active',
                current_period_start=CURRENT_TIMESTAMP,
                current_period_end=DATETIME('now', ?),
                cancel_at_period_end=0,
                provider=excluded.provider,
                provider_subscription_id=excluded.provider_subscription_id,
                updated_at=CURRENT_TIMESTAMP
            """,
            (
                self._login(login),
                product,
                lease_modifier,
                provider,
                provider_subscription_id,
                lease_modifier,
            ),
        )

    def revoke_provider_lease(
        self,
        login,
        product,
        provider,
        provider_subscription_id,
    ):
        cursor = self._connection.execute(
            """
            UPDATE account_subscriptions
            SET status='revoked',
                current_period_end=CURRENT_TIMESTAMP,
                updated_at=CURRENT_TIMESTAMP
            WHERE login=?
              AND product=?
              AND provider=?
              AND provider_subscription_id=?
            """,
            (
                self._login(login),
                product,
                provider,
                provider_subscription_id,
            ),
        )
        return cursor.rowcount > 0

    def mark_cancel_at_period_end(
        self,
        login,
        product,
        provider,
        provider_subscription_id,
    ):
        cursor = self._connection.execute(
            """
            UPDATE account_subscriptions
            SET cancel_at_period_end=1,
                provider=CASE WHEN ? != '' THEN ? ELSE provider END,
                provider_subscription_id=CASE
                    WHEN ? != '' THEN ?
                    ELSE provider_subscription_id
                END,
                updated_at=CURRENT_TIMESTAMP
            WHERE login=? AND product=?
            """,
            (
                provider,
                provider,
                provider_subscription_id,
                provider_subscription_id,
                self._login(login),
                product,
            ),
        )
        return cursor.rowcount > 0

    def record_event(
        self,
        login,
        product,
        event_type,
        payload,
        provider_event_id="",
    ):
        self._connection.execute(
            """
            INSERT INTO subscription_events(
                login,
                product,
                event_type,
                provider_event_id,
                payload_json
            )
            VALUES(?, ?, ?, ?, ?)
            """,
            (
                self._login(login),
                product,
                event_type,
                provider_event_id or None,
                json.dumps(payload, ensure_ascii=False),
            ),
        )

    def rename_product(self, login, old_product, new_product):
        self._connection.execute(
            """
            UPDATE account_subscriptions
            SET product=?, updated_at=CURRENT_TIMESTAMP
            WHERE login=? AND product=?
            """,
            (new_product, self._login(login), old_product),
        )

    def replace_subscription(self, login, product, values):
        self._connection.execute(
            """
            UPDATE account_subscriptions
            SET plan_code=?,
                status=?,
                current_period_start=?,
                current_period_end=?,
                cancel_at_period_end=?,
                provider=?,
                provider_customer_id=?,
                provider_subscription_id=?,
                updated_at=CURRENT_TIMESTAMP
            WHERE login=? AND product=?
            """,
            (*values, self._login(login), product),
        )

    def delete_subscription(self, login, product):
        self._connection.execute(
            """
            DELETE FROM account_subscriptions
            WHERE login=? AND product=?
            """,
            (self._login(login), product),
        )

    def canonicalize_history(
        self,
        login,
        old_product,
        new_product,
    ):
        normalized_login = self._login(login)
        self._connection.execute(
            """
            UPDATE subscription_events
            SET product=?
            WHERE login=? AND product=?
            """,
            (new_product, normalized_login, old_product),
        )
        self._connection.execute(
            """
            UPDATE subscription_orders
            SET product=?
            WHERE login=? AND product=?
            """,
            (new_product, normalized_login, old_product),
        )

    def create_service_session(
        self,
        token_hash,
        login,
        service,
        device_id,
        max_age_days,
    ):
        self._connection.execute(
            """
            INSERT INTO service_sessions(
                token_hash,
                login,
                service,
                device_id,
                expires_at,
                last_used_at
            )
            VALUES(?, ?, ?, ?, DATETIME('now', ?), CURRENT_TIMESTAMP)
            """,
            (
                token_hash,
                self._login(login),
                service,
                device_id,
                f"+{max(1, int(max_age_days))} days",
            ),
        )

    def service_session(self, token_hash, service):
        return self._connection.execute(
            """
            SELECT login, device_id
            FROM service_sessions
            WHERE token_hash=?
              AND service=?
              AND revoked_at IS NULL
              AND expires_at > CURRENT_TIMESTAMP
            """,
            (token_hash, service),
        ).fetchone()

    def touch_service_session(self, token_hash):
        self._connection.execute(
            """
            UPDATE service_sessions
            SET last_used_at=CURRENT_TIMESTAMP
            WHERE token_hash=?
            """,
            (token_hash,),
        )

    def revoke_service_session(self, token_hash, service):
        self._connection.execute(
            """
            UPDATE service_sessions
            SET revoked_at=CURRENT_TIMESTAMP
            WHERE token_hash=? AND service=?
            """,
            (token_hash, service),
        )

    def upsert_boosty_recipient(
        self,
        telegram_user_id,
        private_chat_id,
        telegram_username,
    ):
        self._connection.execute(
            """
            INSERT INTO boosty_key_recipients(
                telegram_user_id,
                private_chat_id,
                telegram_username,
                status,
                next_key_at,
                updated_at
            )
            VALUES(?, ?, ?, 'pending', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            ON CONFLICT(telegram_user_id) DO UPDATE SET
                private_chat_id=excluded.private_chat_id,
                telegram_username=excluded.telegram_username,
                updated_at=CURRENT_TIMESTAMP
            """,
            (
                int(telegram_user_id),
                int(private_chat_id),
                str(telegram_username or "")[:64],
            ),
        )

    def update_boosty_membership(
        self,
        telegram_user_id,
        status=None,
        error="",
    ):
        if status is None:
            self._connection.execute(
                """
                UPDATE boosty_key_recipients
                SET last_membership_check_at=CURRENT_TIMESTAMP,
                    last_error=?,
                    updated_at=CURRENT_TIMESTAMP
                WHERE telegram_user_id=?
                """,
                (str(error or "")[:180], int(telegram_user_id)),
            )
            return
        self._connection.execute(
            """
            UPDATE boosty_key_recipients
            SET status=?,
                last_membership_check_at=CURRENT_TIMESTAMP,
                last_error=?,
                updated_at=CURRENT_TIMESTAMP
            WHERE telegram_user_id=?
            """,
            (
                status,
                str(error or "")[:180],
                int(telegram_user_id),
            ),
        )

    def create_boosty_code(self, code):
        self._connection.execute(
            """
            INSERT INTO boosty_activation_codes(
                code_hash,
                telegram_user_id,
                telegram_username,
                duration_days,
                issue_kind,
                expires_at
            )
            VALUES(?, ?, ?, ?, ?, ?)
            """,
            (
                code["code_hash"],
                int(code["telegram_user_id"]),
                str(code.get("telegram_username") or "")[:64],
                int(code["duration_days"]),
                str(code["issue_kind"])[:24],
                code["expires_at"],
            ),
        )

    def issue_boosty_subscriber_code(self, code, interval_days):
        self.create_boosty_code(code)
        interval_modifier = f"+{max(1, int(interval_days))} days"
        self._connection.execute(
            """
            UPDATE boosty_key_recipients
            SET status='active',
                last_membership_check_at=CURRENT_TIMESTAMP,
                last_key_issued_at=CURRENT_TIMESTAMP,
                next_key_at=DATETIME('now', ?),
                last_error='',
                updated_at=CURRENT_TIMESTAMP
            WHERE telegram_user_id=?
            """,
            (interval_modifier, int(code["telegram_user_id"])),
        )

    def boosty_key_wait_seconds(self, telegram_user_id):
        row = self._connection.execute(
            """
            SELECT CASE
                WHEN next_key_at IS NULL
                  OR next_key_at <= CURRENT_TIMESTAMP
                THEN 0
                ELSE MAX(
                    1,
                    CAST(
                        (JULIANDAY(next_key_at) - JULIANDAY('now')) * 86400
                        AS INTEGER
                    )
                )
            END
            FROM boosty_key_recipients
            WHERE telegram_user_id=?
            """,
            (int(telegram_user_id),),
        ).fetchone()
        return max(0, int(row[0] or 0)) if row else 0

    def active_boosty_code(self, code_hash):
        return self._connection.execute(
            """
            SELECT telegram_user_id, duration_days, issue_kind
            FROM boosty_activation_codes
            WHERE code_hash=?
              AND consumed_at IS NULL
              AND expires_at > CURRENT_TIMESTAMP
            """,
            (code_hash,),
        ).fetchone()

    def consume_boosty_code(self, code_hash, login):
        cursor = self._connection.execute(
            """
            UPDATE boosty_activation_codes
            SET consumed_at=CURRENT_TIMESTAMP,
                redeemed_login=?
            WHERE code_hash=?
              AND consumed_at IS NULL
              AND expires_at > CURRENT_TIMESTAMP
            """,
            (self._login(login), code_hash),
        )
        return cursor.rowcount == 1

    def boosty_recipients(self):
        return self._connection.execute(
            """
            SELECT telegram_user_id, private_chat_id, telegram_username
            FROM boosty_key_recipients
            ORDER BY COALESCE(last_membership_check_at, created_at)
            """
        ).fetchall()

    def revert_boosty_subscriber_code(
        self,
        code_hash,
        telegram_user_id,
        error,
    ):
        cursor = self._connection.execute(
            """
            DELETE FROM boosty_activation_codes
            WHERE code_hash=?
              AND telegram_user_id=?
              AND issue_kind='subscriber'
              AND consumed_at IS NULL
            """,
            (code_hash, int(telegram_user_id)),
        )
        if cursor.rowcount:
            self._connection.execute(
                """
                UPDATE boosty_key_recipients
                SET last_key_issued_at=NULL,
                    next_key_at=CURRENT_TIMESTAMP,
                    last_error=?,
                    updated_at=CURRENT_TIMESTAMP
                WHERE telegram_user_id=?
                """,
                (str(error or "")[:180], int(telegram_user_id)),
            )
        return cursor.rowcount > 0

    def cleanup_boosty_codes(self):
        self._connection.execute(
            """
            DELETE FROM boosty_activation_codes
            WHERE (expires_at <= CURRENT_TIMESTAMP AND consumed_at IS NULL)
               OR consumed_at < DATETIME('now', '-400 days')
            """
        )


class SQLiteUnitOfWork:
    def __init__(
        self,
        connection,
        *,
        write=False,
        transaction_factory=None,
    ):
        self._connection = connection
        self._write = bool(write)
        self._transaction_factory = transaction_factory
        self._transaction = None
        self.identity = SQLiteIdentityRepository(connection)
        self.subscriptions = SQLiteSubscriptionRepository(connection)
        self.billing = SQLiteBillingRepository(connection)

    def __enter__(self):
        if self._write:
            if self._transaction_factory is None:
                raise RuntimeError("write unit of work requires a transaction")
            self._transaction = self._transaction_factory()
        else:
            self._transaction = nullcontext()
        self._transaction.__enter__()
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        if self._transaction is None:
            return False
        return self._transaction.__exit__(
            exc_type,
            exc_value,
            traceback,
        )

    def commit(self):
        if not self._write:
            return
        self._connection.commit()

    def rollback(self):
        if not self._write:
            return
        self._connection.rollback()


class SQLiteUnitOfWorkFactory:
    def __init__(self, connection, transaction_factory):
        self._connection = connection
        self._transaction_factory = transaction_factory

    def __call__(self, *, write=False):
        return SQLiteUnitOfWork(
            self._connection,
            write=write,
            transaction_factory=self._transaction_factory,
        )
