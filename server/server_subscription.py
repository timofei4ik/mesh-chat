import hashlib
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
        with self.unit_of_work_factory() as unit_of_work:
            row = unit_of_work.subscriptions.subscription(
                normalized_login,
                normalized_product,
            )

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
        with self.unit_of_work_factory() as unit_of_work:
            account_exists = unit_of_work.identity.account_exists(
                normalized_login
            )
        if not account_exists:
            raise ValueError("account does not exist")

        normalized_product = self.normalize_subscription_product(product)
        if normalized_product == MESHPRO_PRODUCT:
            self._merge_legacy_meshpro_subscription(normalized_login)
        normalized_plan = (plan_code or "monthly").strip().lower()
        normalized_provider = (provider or "manual").strip().lower()
        duration_days = max(1, int(days))
        normalized_event_id = (provider_event_id or "").strip()
        with self.unit_of_work_factory(write=True) as unit_of_work:
            if (
                normalized_event_id
                and unit_of_work.subscriptions.provider_event_exists(
                    normalized_event_id
                )
            ):
                return self.subscription_status(
                    normalized_login,
                    normalized_product,
                )
            unit_of_work.subscriptions.grant(
                normalized_login,
                normalized_product,
                normalized_plan,
                duration_days,
                normalized_provider,
                provider_subscription_id or "",
            )
            unit_of_work.subscriptions.record_event(
                normalized_login,
                normalized_product,
                "granted",
                {
                    "plan_code": normalized_plan,
                    "days": duration_days,
                    "provider": normalized_provider,
                },
                normalized_event_id,
            )
        return self.subscription_status(normalized_login, normalized_product)

    def revoke_subscription(self, login, product=MESHPRO_PRODUCT):
        normalized_login = (login or "").strip().lower()
        normalized_product = self.normalize_subscription_product(product)
        products = (
            tuple(MESHPRO_PRODUCT_ALIASES)
            if normalized_product == MESHPRO_PRODUCT
            else (normalized_product,)
        )
        with self.unit_of_work_factory(write=True) as unit_of_work:
            unit_of_work.subscriptions.revoke(normalized_login, products)
            unit_of_work.subscriptions.record_event(
                normalized_login,
                normalized_product,
                "revoked",
                {},
            )
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
        with self.unit_of_work_factory() as unit_of_work:
            account_exists = unit_of_work.identity.account_exists(
                normalized_login
            )
        if not account_exists:
            raise ValueError("account does not exist")

        with self.unit_of_work_factory() as unit_of_work:
            existing = unit_of_work.subscriptions.subscription(
                normalized_login,
                normalized_product,
            )
        if existing:
            existing_end = self._parse_subscription_time(existing[3])
            existing_active = (
                existing[1] in SUBSCRIPTION_ACTIVE_STATUSES
                and (
                    existing_end is None
                    or existing_end > datetime.now(timezone.utc)
                )
            )
            if (
                existing_active
                and (existing[5] or "").strip().lower()
                not in {"", normalized_provider}
            ):
                return self.subscription_status(
                    normalized_login,
                    normalized_product,
                )

        with self.unit_of_work_factory(write=True) as unit_of_work:
            unit_of_work.subscriptions.set_provider_lease(
                normalized_login,
                normalized_product,
                normalized_provider,
                normalized_subscription_id,
                lease_hours,
            )
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
        with self.unit_of_work_factory(write=True) as unit_of_work:
            changed = unit_of_work.subscriptions.revoke_provider_lease(
                normalized_login,
                normalized_product,
                normalized_provider,
                normalized_subscription_id,
            )
            if changed:
                unit_of_work.subscriptions.record_event(
                    normalized_login,
                    normalized_product,
                    "provider_revoked",
                    {
                        "provider": normalized_provider,
                        "provider_subscription_id": (
                            normalized_subscription_id
                        ),
                    },
                )
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
        with self.unit_of_work_factory(write=True) as unit_of_work:
            if unit_of_work.subscriptions.provider_event_exists(
                normalized_event_id
            ):
                return False
            unit_of_work.subscriptions.record_event(
                (login or "").strip().lower(),
                self.normalize_subscription_product(product),
                event_type,
                payload,
                normalized_event_id,
            )
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
        with self.unit_of_work_factory(write=True) as unit_of_work:
            if (
                normalized_event_id
                and unit_of_work.subscriptions.provider_event_exists(
                    normalized_event_id
                )
            ):
                return self.subscription_status(
                    normalized_login,
                    normalized_product,
                )
            normalized_provider = (provider or "").strip().lower()
            normalized_subscription_id = (
                provider_subscription_id or ""
            ).strip()
            changed = (
                unit_of_work.subscriptions.mark_cancel_at_period_end(
                    normalized_login,
                    normalized_product,
                    normalized_provider,
                    normalized_subscription_id,
                )
            )
            if not changed:
                raise ValueError("subscription does not exist")
            unit_of_work.subscriptions.record_event(
                normalized_login,
                normalized_product,
                "cancel_at_period_end",
                {
                    "provider": normalized_provider,
                    "provider_subscription_id": normalized_subscription_id,
                },
                normalized_event_id,
            )
        return self.subscription_status(normalized_login, normalized_product)

    def create_service_session(self, login, service, device_id):
        normalized_login = (login or "").strip().lower()
        normalized_service = (service or "").strip().lower()
        if not normalized_login or not normalized_service:
            raise ValueError("login and service are required")

        token = secrets.token_urlsafe(32)
        with self.unit_of_work_factory(write=True) as unit_of_work:
            unit_of_work.subscriptions.create_service_session(
                self._hash_service_token(token),
                normalized_login,
                normalized_service,
                (device_id or "").strip(),
                SERVICE_SESSION_MAX_AGE_DAYS,
            )
        return token

    def authenticate_service_session(self, token, service, device_id=None):
        token_hash = self._hash_service_token(token or "")
        normalized_service = (service or "").strip().lower()
        with self.unit_of_work_factory() as unit_of_work:
            row = unit_of_work.subscriptions.service_session(
                token_hash,
                normalized_service,
            )
        if not row:
            return None

        expected_device = (row[1] or "").strip()
        actual_device = (device_id or "").strip()
        if expected_device and expected_device != actual_device:
            return None

        with self.unit_of_work_factory(write=True) as unit_of_work:
            unit_of_work.subscriptions.touch_service_session(token_hash)
        return row[0]

    def revoke_service_session(self, token, service):
        with self.unit_of_work_factory(write=True) as unit_of_work:
            unit_of_work.subscriptions.revoke_service_session(
                self._hash_service_token(token or ""),
                (service or "").strip().lower(),
            )

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
        with self.unit_of_work_factory() as unit_of_work:
            rows = unit_of_work.subscriptions.subscriptions(
                login,
                (MESHPRO_PRODUCT, "meshprivacy"),
            )
        legacy = next((row for row in rows if row[0] == "meshprivacy"), None)
        canonical = next((row for row in rows if row[0] == MESHPRO_PRODUCT), None)
        if legacy is None:
            return

        if canonical is None:
            with self.unit_of_work_factory(write=True) as unit_of_work:
                unit_of_work.subscriptions.rename_product(
                    login,
                    "meshprivacy",
                    MESHPRO_PRODUCT,
                )
                unit_of_work.subscriptions.canonicalize_history(
                    login,
                    "meshprivacy",
                    MESHPRO_PRODUCT,
                )
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
            winning_values = legacy[1:9]
        else:
            winning_values = None
        with self.unit_of_work_factory(write=True) as unit_of_work:
            if winning_values is not None:
                unit_of_work.subscriptions.replace_subscription(
                    login,
                    MESHPRO_PRODUCT,
                    winning_values,
                )
            unit_of_work.subscriptions.delete_subscription(
                login,
                "meshprivacy",
            )
            unit_of_work.subscriptions.canonicalize_history(
                login,
                "meshprivacy",
                MESHPRO_PRODUCT,
            )

    def _canonicalize_meshpro_history(self, login):
        with self.unit_of_work_factory(write=True) as unit_of_work:
            unit_of_work.subscriptions.canonicalize_history(
                login,
                "meshprivacy",
                MESHPRO_PRODUCT,
            )

    def _record_subscription_event(
        self,
        login,
        product,
        event_type,
        payload,
        provider_event_id="",
    ):
        with self.unit_of_work_factory(write=True) as unit_of_work:
            unit_of_work.subscriptions.record_event(
                login,
                product,
                event_type,
                payload,
                provider_event_id,
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
