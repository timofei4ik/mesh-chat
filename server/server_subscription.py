import hashlib
import json
import secrets
from datetime import datetime, timezone

try:
    from server.config import (
        MESHPRO_MONTHLY_DAYS,
        MESHPRO_MONTHLY_PRICE,
        SUBSCRIPTION_CHECKOUT_URL,
        SUBSCRIPTION_MANAGE_URL,
    )
    from server.meshpro_catalog import (
        MESHPRO_PRODUCT,
        build_meshpro_catalog,
        build_meshpro_entitlements,
    )
except ModuleNotFoundError:
    from config import (
        MESHPRO_MONTHLY_DAYS,
        MESHPRO_MONTHLY_PRICE,
        SUBSCRIPTION_CHECKOUT_URL,
        SUBSCRIPTION_MANAGE_URL,
    )
    from meshpro_catalog import (
        MESHPRO_PRODUCT,
        build_meshpro_catalog,
        build_meshpro_entitlements,
    )


SUBSCRIPTION_ACTIVE_STATUSES = frozenset({"active", "trialing"})
SERVICE_SESSION_MAX_AGE_DAYS = 30
MESHPRO_PRODUCT_ALIASES = frozenset({MESHPRO_PRODUCT, "meshprivacy"})


class ServerSubscriptionMixin:
    def normalize_subscription_product(self, product=None):
        normalized_product = (product or MESHPRO_PRODUCT).strip().lower()
        if normalized_product in MESHPRO_PRODUCT_ALIASES:
            return MESHPRO_PRODUCT
        return normalized_product

    def subscription_offer(self, product=MESHPRO_PRODUCT):
        normalized_product = self.normalize_subscription_product(product)
        if normalized_product != MESHPRO_PRODUCT:
            return {
                "checkout_available": False,
                "price_value": None,
                "currency": None,
                "period_days": None,
            }
        return {
            "checkout_available": bool(
                getattr(self, "subscription_checkout_ready", False)
            ),
            "price_value": MESHPRO_MONTHLY_PRICE,
            "currency": "RUB",
            "period_days": max(1, int(MESHPRO_MONTHLY_DAYS)),
        }

    def subscription_catalog(self, product=MESHPRO_PRODUCT):
        normalized_product = self.normalize_subscription_product(product)
        if normalized_product != MESHPRO_PRODUCT:
            return None
        return build_meshpro_catalog()

    def subscription_entitlements(
        self,
        active,
        product=MESHPRO_PRODUCT,
    ):
        normalized_product = self.normalize_subscription_product(product)
        if normalized_product != MESHPRO_PRODUCT:
            return None
        return build_meshpro_entitlements(active)

    def subscription_status(self, login, product=MESHPRO_PRODUCT):
        normalized_login = (login or "").strip().lower()
        normalized_product = self.normalize_subscription_product(product)
        if normalized_product == MESHPRO_PRODUCT:
            self._merge_legacy_meshpro_subscription(normalized_login)
        offer = self.subscription_offer(normalized_product)
        row = self.db.execute(
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
            (normalized_login, normalized_product),
        ).fetchone()

        if not row:
            status = {
                "product": normalized_product,
                "plan_code": "none",
                "status": "inactive",
                "active": False,
                "current_period_start": None,
                "current_period_end": None,
                "cancel_at_period_end": False,
                "provider": "none",
                "updated_at": None,
                "checkout_url": (
                    SUBSCRIPTION_CHECKOUT_URL
                    if offer["checkout_available"]
                    else ""
                ),
                "manage_url": SUBSCRIPTION_MANAGE_URL,
                **offer,
            }
            entitlements = self.subscription_entitlements(
                False,
                normalized_product,
            )
            if entitlements is not None:
                status["entitlements"] = entitlements
            return status

        period_end = self._parse_subscription_time(row[3])
        active = row[1] in SUBSCRIPTION_ACTIVE_STATUSES and (
            period_end is None or period_end > datetime.now(timezone.utc)
        )
        status = row[1]
        if not active and status in SUBSCRIPTION_ACTIVE_STATUSES:
            status = "expired"

        result = {
            "product": normalized_product,
            "plan_code": row[0] or "none",
            "status": status,
            "active": active,
            "current_period_start": row[2],
            "current_period_end": row[3],
            "cancel_at_period_end": bool(row[4]),
            "provider": row[5] or "manual",
            "updated_at": row[6],
            "checkout_url": (
                SUBSCRIPTION_CHECKOUT_URL
                if offer["checkout_available"]
                else ""
            ),
            "manage_url": SUBSCRIPTION_MANAGE_URL,
            **offer,
        }
        entitlements = self.subscription_entitlements(
            active,
            normalized_product,
        )
        if entitlements is not None:
            result["entitlements"] = entitlements
        return result

    def has_active_subscription(self, login, product=MESHPRO_PRODUCT):
        return bool(self.subscription_status(login, product).get("active"))

    def subscription_feature_enabled(
        self,
        login,
        feature_id,
        product=MESHPRO_PRODUCT,
    ):
        status = self.subscription_status(login, product)
        features = (
            status.get("entitlements", {}).get("features", {})
        )
        return bool(status.get("active") and features.get(feature_id))

    def grant_subscription(
        self,
        login,
        product=MESHPRO_PRODUCT,
        plan_code="monthly",
        days=30,
        provider="manual",
        provider_subscription_id="",
        provider_event_id="",
    ):
        normalized_login = (login or "").strip().lower()
        if not normalized_login:
            raise ValueError("login is required")
        account = self.db.execute(
            "SELECT 1 FROM accounts WHERE login=?",
            (normalized_login,),
        ).fetchone()
        if not account:
            raise ValueError("account does not exist")

        normalized_product = self.normalize_subscription_product(product)
        if normalized_product == MESHPRO_PRODUCT:
            self._merge_legacy_meshpro_subscription(normalized_login)
        normalized_plan = (plan_code or "monthly").strip().lower()
        normalized_provider = (provider or "manual").strip().lower()
        duration_days = max(1, int(days))
        period_modifier = f"+{duration_days} days"

        normalized_event_id = (provider_event_id or "").strip()
        if normalized_event_id:
            duplicate = self.db.execute(
                """
                SELECT 1
                FROM subscription_events
                WHERE provider_event_id=?
                """,
                (normalized_event_id,),
            ).fetchone()
            if duplicate:
                return self.subscription_status(
                    normalized_login,
                    normalized_product,
                )

        self.db.execute(
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
                    WHEN account_subscriptions.current_period_end > CURRENT_TIMESTAMP
                    THEN account_subscriptions.current_period_start
                    ELSE CURRENT_TIMESTAMP
                END,
                current_period_end=DATETIME(
                    CASE
                        WHEN account_subscriptions.current_period_end > CURRENT_TIMESTAMP
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
                normalized_login,
                normalized_product,
                normalized_plan,
                period_modifier,
                normalized_provider,
                provider_subscription_id or "",
                period_modifier,
            ),
        )
        self._record_subscription_event(
            normalized_login,
            normalized_product,
            "granted",
            {
                "plan_code": normalized_plan,
                "days": duration_days,
                "provider": normalized_provider,
            },
            provider_event_id=normalized_event_id,
        )
        self.db.commit()
        return self.subscription_status(normalized_login, normalized_product)

    def revoke_subscription(self, login, product=MESHPRO_PRODUCT):
        normalized_login = (login or "").strip().lower()
        normalized_product = self.normalize_subscription_product(product)
        products = (
            tuple(MESHPRO_PRODUCT_ALIASES)
            if normalized_product == MESHPRO_PRODUCT
            else (normalized_product,)
        )
        placeholders = ",".join("?" for _ in products)
        self.db.execute(
            f"""
            UPDATE account_subscriptions
            SET status='revoked',
                current_period_end=CURRENT_TIMESTAMP,
                updated_at=CURRENT_TIMESTAMP
            WHERE login=? AND product IN ({placeholders})
            """,
            (normalized_login, *products),
        )
        self._record_subscription_event(
            normalized_login,
            normalized_product,
            "revoked",
            {},
        )
        self.db.commit()
        failures = []
        if hasattr(self, "revoke_wireguard_peers"):
            failures = self.revoke_wireguard_peers(
                normalized_login,
                normalized_product,
            )
        result = self.subscription_status(normalized_login, normalized_product)
        if failures:
            result["vpn_revoke_failures"] = failures
        return result

    def set_provider_subscription_lease(
        self,
        login,
        provider,
        provider_subscription_id,
        lease_hours,
        product=MESHPRO_PRODUCT,
    ):
        normalized_login = (login or "").strip().lower()
        normalized_provider = (provider or "").strip().lower()
        normalized_subscription_id = (
            provider_subscription_id or ""
        ).strip()
        normalized_product = self.normalize_subscription_product(product)
        if not normalized_login or not normalized_provider:
            raise ValueError("login and provider are required")
        if not normalized_subscription_id:
            raise ValueError("provider subscription id is required")
        if not self.db.execute(
            "SELECT 1 FROM accounts WHERE login=?",
            (normalized_login,),
        ).fetchone():
            raise ValueError("account does not exist")

        existing = self.db.execute(
            """
            SELECT provider, status, current_period_end
            FROM account_subscriptions
            WHERE login=? AND product=?
            """,
            (normalized_login, normalized_product),
        ).fetchone()
        if existing:
            existing_end = self._parse_subscription_time(existing[2])
            existing_active = (
                existing[1] in SUBSCRIPTION_ACTIVE_STATUSES
                and (
                    existing_end is None
                    or existing_end > datetime.now(timezone.utc)
                )
            )
            if (
                existing_active
                and (existing[0] or "").strip().lower()
                not in {"", normalized_provider}
            ):
                return self.subscription_status(
                    normalized_login,
                    normalized_product,
                )

        lease_modifier = f"+{max(1, int(lease_hours))} hours"
        self.db.execute(
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
                normalized_login,
                normalized_product,
                lease_modifier,
                normalized_provider,
                normalized_subscription_id,
                lease_modifier,
            ),
        )
        self.db.commit()
        return self.subscription_status(normalized_login, normalized_product)

    def revoke_provider_subscription_lease(
        self,
        login,
        provider,
        provider_subscription_id,
        product=MESHPRO_PRODUCT,
    ):
        normalized_login = (login or "").strip().lower()
        normalized_provider = (provider or "").strip().lower()
        normalized_subscription_id = (
            provider_subscription_id or ""
        ).strip()
        normalized_product = self.normalize_subscription_product(product)
        cursor = self.db.execute(
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
                normalized_login,
                normalized_product,
                normalized_provider,
                normalized_subscription_id,
            ),
        )
        changed = cursor.rowcount > 0
        if changed:
            self._record_subscription_event(
                normalized_login,
                normalized_product,
                "provider_revoked",
                {
                    "provider": normalized_provider,
                    "provider_subscription_id": normalized_subscription_id,
                },
            )
        self.db.commit()
        failures = []
        if changed and hasattr(self, "revoke_wireguard_peers"):
            failures = self.revoke_wireguard_peers(
                normalized_login,
                normalized_product,
            )
        result = self.subscription_status(normalized_login, normalized_product)
        result["provider_lease_revoked"] = changed
        if failures:
            result["vpn_revoke_failures"] = failures
        return result

    def record_subscription_event_once(
        self,
        login,
        product,
        event_type,
        payload,
        provider_event_id,
    ):
        normalized_event_id = (provider_event_id or "").strip()
        if not normalized_event_id:
            raise ValueError("provider event id is required")
        duplicate = self.db.execute(
            """
            SELECT 1
            FROM subscription_events
            WHERE provider_event_id=?
            """,
            (normalized_event_id,),
        ).fetchone()
        if duplicate:
            return False
        self._record_subscription_event(
            (login or "").strip().lower(),
            self.normalize_subscription_product(product),
            event_type,
            payload,
            provider_event_id=normalized_event_id,
        )
        self.db.commit()
        return True

    def mark_subscription_cancel_at_period_end(
        self,
        login,
        product=MESHPRO_PRODUCT,
        provider="",
        provider_subscription_id="",
        provider_event_id="",
    ):
        normalized_login = (login or "").strip().lower()
        normalized_product = self.normalize_subscription_product(product)
        normalized_event_id = (provider_event_id or "").strip()
        if normalized_event_id:
            duplicate = self.db.execute(
                """
                SELECT 1
                FROM subscription_events
                WHERE provider_event_id=?
                """,
                (normalized_event_id,),
            ).fetchone()
            if duplicate:
                return self.subscription_status(
                    normalized_login,
                    normalized_product,
                )

        row = self.db.execute(
            """
            SELECT 1
            FROM account_subscriptions
            WHERE login=? AND product=?
            """,
            (normalized_login, normalized_product),
        ).fetchone()
        if not row:
            raise ValueError("subscription does not exist")

        self.db.execute(
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
                (provider or "").strip().lower(),
                (provider or "").strip().lower(),
                (provider_subscription_id or "").strip(),
                (provider_subscription_id or "").strip(),
                normalized_login,
                normalized_product,
            ),
        )
        self._record_subscription_event(
            normalized_login,
            normalized_product,
            "cancel_at_period_end",
            {
                "provider": (provider or "").strip().lower(),
                "provider_subscription_id": (
                    provider_subscription_id or ""
                ).strip(),
            },
            provider_event_id=normalized_event_id,
        )
        self.db.commit()
        return self.subscription_status(normalized_login, normalized_product)

    def create_service_session(self, login, service, device_id):
        normalized_login = (login or "").strip().lower()
        normalized_service = (service or "").strip().lower()
        if not normalized_login or not normalized_service:
            raise ValueError("login and service are required")

        token = secrets.token_urlsafe(32)
        self.db.execute(
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
                self._hash_service_token(token),
                normalized_login,
                normalized_service,
                (device_id or "").strip(),
                f"+{SERVICE_SESSION_MAX_AGE_DAYS} days",
            ),
        )
        self.db.commit()
        return token

    def authenticate_service_session(self, token, service, device_id=None):
        token_hash = self._hash_service_token(token or "")
        normalized_service = (service or "").strip().lower()
        row = self.db.execute(
            """
            SELECT login, device_id
            FROM service_sessions
            WHERE token_hash=?
              AND service=?
              AND revoked_at IS NULL
              AND expires_at > CURRENT_TIMESTAMP
            """,
            (token_hash, normalized_service),
        ).fetchone()
        if not row:
            return None

        expected_device = (row[1] or "").strip()
        actual_device = (device_id or "").strip()
        if expected_device and expected_device != actual_device:
            return None

        self.db.execute(
            """
            UPDATE service_sessions
            SET last_used_at=CURRENT_TIMESTAMP
            WHERE token_hash=?
            """,
            (token_hash,),
        )
        self.db.commit()
        return row[0]

    def revoke_service_session(self, token, service):
        self.db.execute(
            """
            UPDATE service_sessions
            SET revoked_at=CURRENT_TIMESTAMP
            WHERE token_hash=? AND service=?
            """,
            (
                self._hash_service_token(token or ""),
                (service or "").strip().lower(),
            ),
        )
        self.db.commit()

    def vpn_config_for(self, login, device_id):
        status = self.subscription_status(login, MESHPRO_PRODUCT)
        if not status["active"]:
            if hasattr(self, "revoke_wireguard_peers"):
                self.revoke_wireguard_peers(login, MESHPRO_PRODUCT, device_id)
            return None, status, "subscription_required"

        normalized_device = (device_id or "").strip()
        if not normalized_device:
            return None, status, "device_id_required"
        if not hasattr(self, "wireguard_config_for"):
            return None, status, "vpn_config_unavailable"

        try:
            config = self.wireguard_config_for(login, normalized_device)
        except Exception as error:
            print(f"WireGuard provisioning failed for {login}: {error}")
            return None, status, "vpn_provisioning_failed"
        return config, status, "ok" if config else "vpn_config_unavailable"

    def _merge_legacy_meshpro_subscription(self, login):
        if not login:
            return
        rows = self.db.execute(
            """
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
            WHERE login=? AND product IN ('meshpro', 'meshprivacy')
            """,
            (login,),
        ).fetchall()
        legacy = next((row for row in rows if row[0] == "meshprivacy"), None)
        canonical = next((row for row in rows if row[0] == MESHPRO_PRODUCT), None)
        if legacy is None:
            return

        if canonical is None:
            self.db.execute(
                """
                UPDATE account_subscriptions
                SET product=?, updated_at=CURRENT_TIMESTAMP
                WHERE login=? AND product='meshprivacy'
                """,
                (MESHPRO_PRODUCT, login),
            )
            self._canonicalize_meshpro_history(login)
            self.db.commit()
            return

        now = datetime.now(timezone.utc)
        legacy_end = self._parse_subscription_time(legacy[4])
        canonical_end = self._parse_subscription_time(canonical[4])
        legacy_active = legacy[2] in SUBSCRIPTION_ACTIVE_STATUSES and (
            legacy_end is None or legacy_end > now
        )
        canonical_active = canonical[2] in SUBSCRIPTION_ACTIVE_STATUSES and (
            canonical_end is None or canonical_end > now
        )
        legacy_wins = legacy_active and not canonical_active
        if legacy_active == canonical_active:
            legacy_wins = legacy_end is None or bool(
                canonical_end is not None and legacy_end > canonical_end
            )
        if legacy_wins:
            self.db.execute(
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
                (*legacy[1:9], login, MESHPRO_PRODUCT),
            )
        self.db.execute(
            "DELETE FROM account_subscriptions WHERE login=? AND product='meshprivacy'",
            (login,),
        )
        self._canonicalize_meshpro_history(login)
        self.db.commit()

    def _canonicalize_meshpro_history(self, login):
        self.db.execute(
            "UPDATE subscription_events SET product=? WHERE login=? AND product='meshprivacy'",
            (MESHPRO_PRODUCT, login),
        )
        self.db.execute(
            "UPDATE subscription_orders SET product=? WHERE login=? AND product='meshprivacy'",
            (MESHPRO_PRODUCT, login),
        )

    def _record_subscription_event(
        self,
        login,
        product,
        event_type,
        payload,
        provider_event_id="",
    ):
        self.db.execute(
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
                login,
                product,
                event_type,
                provider_event_id or None,
                json.dumps(payload, ensure_ascii=False),
            ),
        )

    def _hash_service_token(self, token):
        return hashlib.sha256((token or "").encode("utf-8")).hexdigest()

    def _parse_subscription_time(self, value):
        if not value:
            return None
        try:
            parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        except ValueError:
            return None
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)
