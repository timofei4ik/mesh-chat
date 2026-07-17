import hashlib
import json
import re
import secrets
import uuid
from decimal import Decimal, InvalidOperation
from urllib.parse import urlencode, urlparse, urlunparse, parse_qsl

try:
    import aiohttp
except ModuleNotFoundError:  # Installed from server/requirements.txt in production.
    aiohttp = None

try:
    from server.config import (
        LAVA_API_KEY,
        LAVA_API_URL,
        LAVA_OFFER_ID,
        LAVA_PRODUCT_ID,
        LAVA_WEBHOOK_KEY,
        MESHPRO_MONTHLY_DAYS,
        MESHPRO_MONTHLY_PRICE,
        SBER_PAYMENT_URL,
        SUBSCRIPTION_CHECKOUT_URL,
        YOOKASSA_API_URL,
        YOOKASSA_RETURN_URL,
        YOOKASSA_SECRET_KEY,
        YOOKASSA_SHOP_ID,
        YOOKASSA_WEBHOOK_SECRET,
        WIREGUARD_ENABLED,
        WIREGUARD_ENDPOINT,
    )
except ModuleNotFoundError:
    from config import (
        LAVA_API_KEY,
        LAVA_API_URL,
        LAVA_OFFER_ID,
        LAVA_PRODUCT_ID,
        LAVA_WEBHOOK_KEY,
        MESHPRO_MONTHLY_DAYS,
        MESHPRO_MONTHLY_PRICE,
        SBER_PAYMENT_URL,
        SUBSCRIPTION_CHECKOUT_URL,
        YOOKASSA_API_URL,
        YOOKASSA_RETURN_URL,
        YOOKASSA_SECRET_KEY,
        YOOKASSA_SHOP_ID,
        YOOKASSA_WEBHOOK_SECRET,
        WIREGUARD_ENABLED,
        WIREGUARD_ENDPOINT,
    )


class BillingError(RuntimeError):
    pass


class ServerBillingMixin:
    @property
    def manual_billing_configured(self):
        return bool(
            self._validated_sber_payment_url()
            and SUBSCRIPTION_CHECKOUT_URL
        )

    @property
    def billing_configured(self):
        return bool(
            self.lava_billing_configured
            or self.yookassa_billing_configured
        )

    @property
    def lava_billing_configured(self):
        return bool(
            LAVA_API_KEY
            and LAVA_WEBHOOK_KEY
            and LAVA_PRODUCT_ID
            and LAVA_OFFER_ID
            and SUBSCRIPTION_CHECKOUT_URL
        )

    @property
    def yookassa_billing_configured(self):
        return bool(
            YOOKASSA_SHOP_ID
            and YOOKASSA_SECRET_KEY
            and YOOKASSA_WEBHOOK_SECRET
        )

    @property
    def subscription_checkout_ready(self):
        return bool(
            (self.billing_configured or self.manual_billing_configured)
            and WIREGUARD_ENABLED
            and WIREGUARD_ENDPOINT
        )

    @property
    def active_billing_provider(self):
        if self.lava_billing_configured:
            return "lava"
        if self.yookassa_billing_configured:
            return "yookassa"
        if self.manual_billing_configured:
            return "sber_manual"
        return "none"

    async def create_subscription_checkout(
        self,
        login,
        device_id,
        client_request_id,
        product="meshpro",
        plan_code="monthly",
        buyer_email="",
    ):
        if not self.billing_configured and not self.manual_billing_configured:
            raise BillingError("billing is not configured")
        if not self.subscription_checkout_ready:
            raise BillingError("the VPN backend is not ready")
        normalized_login = (login or "").strip().lower()
        normalized_product = self.normalize_subscription_product(product)
        normalized_plan = (plan_code or "monthly").strip().lower()
        if normalized_product != "meshpro" or normalized_plan != "monthly":
            raise BillingError("unknown subscription plan")

        account = self.db.execute(
            "SELECT 1 FROM accounts WHERE login=?",
            (normalized_login,),
        ).fetchone()
        if not account:
            raise BillingError("account does not exist")

        if not self.billing_configured:
            result = self.create_manual_subscription_order(normalized_login)
            result["confirmation_url"] = self._checkout_page_url(
                normalized_login
            )
            return result

        if self.lava_billing_configured:
            normalized_email = self._normalize_buyer_email(buyer_email)
            if not normalized_email:
                return {
                    "order_id": "",
                    "provider": "lava",
                    "status": "email_required",
                    "confirmation_url": self._checkout_page_url(
                        normalized_login
                    ),
                    "amount_value": self._monthly_price(),
                    "currency": "RUB",
                    "duration_days": max(1, int(MESHPRO_MONTHLY_DAYS)),
                }
            return await self._create_lava_checkout(
                normalized_login,
                normalized_email,
                device_id,
                client_request_id,
                normalized_product,
                normalized_plan,
            )

        reusable = self.db.execute(
            """
            SELECT order_id
            FROM subscription_orders
            WHERE login=?
              AND product=?
              AND plan_code=?
              AND provider='yookassa'
              AND status='pending'
              AND confirmation_url != ''
              AND created_at > DATETIME('now', '-30 minutes')
            ORDER BY created_at DESC
            LIMIT 1
            """,
            (normalized_login, normalized_product, normalized_plan),
        ).fetchone()
        if reusable:
            return self._checkout_result(reusable[0])

        amount_value = self._monthly_price()
        duration_days = max(1, int(MESHPRO_MONTHLY_DAYS))
        request_seed = "|".join(
            [
                normalized_login,
                normalized_product,
                normalized_plan,
                (device_id or "").strip(),
                (client_request_id or str(uuid.uuid4())).strip(),
            ]
        )
        checkout_key = hashlib.sha256(request_seed.encode("utf-8")).hexdigest()
        row = self.db.execute(
            """
            SELECT order_id,
                   provider_payment_id,
                   status,
                   confirmation_url
            FROM subscription_orders
            WHERE checkout_key=?
            """,
            (checkout_key,),
        ).fetchone()
        if row and row[1] and row[3]:
            return self._checkout_result(row[0])

        order_id = row[0] if row else str(uuid.uuid4())
        if not row:
            self.db.execute(
                """
                INSERT INTO subscription_orders(
                    order_id,
                    checkout_key,
                    login,
                    product,
                    plan_code,
                    duration_days,
                    amount_value,
                    currency,
                    provider,
                    status
                )
                VALUES(?, ?, ?, ?, ?, ?, ?, 'RUB', 'yookassa', 'creating')
                """,
                (
                    order_id,
                    checkout_key,
                    normalized_login,
                    normalized_product,
                    normalized_plan,
                    duration_days,
                    amount_value,
                ),
            )
            self.db.commit()

        payment_payload = {
            "amount": {"value": amount_value, "currency": "RUB"},
            "capture": True,
            "confirmation": {
                "type": "redirect",
                "return_url": YOOKASSA_RETURN_URL,
            },
            "description": f"MeshPro: {duration_days} days for @{normalized_login}",
            "metadata": {
                "mesh_order_id": order_id,
                "login": normalized_login,
                "product": normalized_product,
                "plan_code": normalized_plan,
                "duration_days": str(duration_days),
            },
        }
        try:
            payment = await self._yookassa_request(
                "POST",
                "/payments",
                payment_payload,
                checkout_key,
            )
        except Exception:
            self.db.execute(
                """
                UPDATE subscription_orders
                SET status='checkout_error', updated_at=CURRENT_TIMESTAMP
                WHERE order_id=?
                """,
                (order_id,),
            )
            self.db.commit()
            raise

        payment_id = str(payment.get("id") or "").strip()
        confirmation = payment.get("confirmation") or {}
        confirmation_url = str(
            confirmation.get("confirmation_url") or ""
        ).strip()
        succeeded = (
            payment.get("status") == "succeeded"
            and payment.get("paid") is True
        )
        if succeeded and not confirmation_url:
            confirmation_url = YOOKASSA_RETURN_URL
        if not payment_id or not confirmation_url:
            raise BillingError("YooKassa did not return a confirmation URL")
        self.db.execute(
            """
            UPDATE subscription_orders
            SET provider_payment_id=?,
                status=?,
                confirmation_url=?,
                updated_at=CURRENT_TIMESTAMP
            WHERE order_id=?
            """,
            (
                payment_id,
                str(payment.get("status") or "pending"),
                confirmation_url,
                order_id,
            ),
        )
        self.db.commit()
        if succeeded:
            self._apply_verified_payment(payment, "payment.succeeded")
        return self._checkout_result(order_id)

    async def _create_lava_checkout(
        self,
        login,
        buyer_email,
        device_id,
        client_request_id,
        product,
        plan_code,
    ):
        reusable = self.db.execute(
            """
            SELECT order_id
            FROM subscription_orders
            WHERE login=?
              AND product=?
              AND plan_code=?
              AND provider='lava'
              AND buyer_email=?
              AND status IN ('creating', 'NEW', 'IN_PROGRESS', 'pending')
              AND confirmation_url != ''
              AND created_at > DATETIME('now', '-30 minutes')
            ORDER BY created_at DESC
            LIMIT 1
            """,
            (login, product, plan_code, buyer_email),
        ).fetchone()
        if reusable:
            return self._checkout_result(reusable[0])

        amount_value = self._monthly_price()
        duration_days = max(1, int(MESHPRO_MONTHLY_DAYS))
        request_seed = "|".join(
            [
                "lava",
                login,
                buyer_email,
                product,
                plan_code,
                (device_id or "").strip(),
                (client_request_id or str(uuid.uuid4())).strip(),
            ]
        )
        checkout_key = hashlib.sha256(
            request_seed.encode("utf-8")
        ).hexdigest()
        row = self.db.execute(
            """
            SELECT order_id, provider_payment_id, confirmation_url
            FROM subscription_orders
            WHERE checkout_key=?
            """,
            (checkout_key,),
        ).fetchone()
        if row and row[1] and row[2]:
            return self._checkout_result(row[0])

        order_id = row[0] if row else str(uuid.uuid4())
        if not row:
            self.db.execute(
                """
                INSERT INTO subscription_orders(
                    order_id,
                    checkout_key,
                    login,
                    product,
                    plan_code,
                    duration_days,
                    amount_value,
                    currency,
                    provider,
                    status,
                    buyer_email,
                    provider_product_id,
                    provider_offer_id
                )
                VALUES(?, ?, ?, ?, ?, ?, ?, 'RUB', 'lava', 'creating',
                       ?, ?, ?)
                """,
                (
                    order_id,
                    checkout_key,
                    login,
                    product,
                    plan_code,
                    duration_days,
                    amount_value,
                    buyer_email,
                    LAVA_PRODUCT_ID,
                    LAVA_OFFER_ID,
                ),
            )
            self.db.commit()

        invoice_payload = {
            "email": buyer_email,
            "offerId": LAVA_OFFER_ID,
            "currency": "RUB",
            "buyerLanguage": "RU",
            "periodicity": "MONTHLY",
            "clientUtm": {
                "utm_source": "meshchat",
                "utm_medium": "meshpro",
                "utm_campaign": order_id,
            },
        }
        try:
            invoice = await self._lava_request(
                "POST",
                "/api/v3/invoice",
                invoice_payload,
            )
            invoice_id = str(invoice.get("id") or "").strip()
            payment_url = str(invoice.get("paymentUrl") or "").strip()
            if not invoice_id or not self._validated_https_url(payment_url):
                raise BillingError(
                    "Lava did not return a valid payment URL"
                )
            amount_total = invoice.get("amountTotal") or {}
            if amount_total:
                if self._money(
                    amount_total.get("amount")
                ) != self._money(amount_value):
                    raise BillingError("Lava invoice amount mismatch")
                if str(amount_total.get("currency") or "").upper() != "RUB":
                    raise BillingError("Lava invoice currency mismatch")
        except Exception:
            self.db.execute(
                """
                UPDATE subscription_orders
                SET status='checkout_error', updated_at=CURRENT_TIMESTAMP
                WHERE order_id=?
                """,
                (order_id,),
            )
            self.db.commit()
            raise

        self.db.execute(
            """
            UPDATE subscription_orders
            SET provider_payment_id=?,
                status=?,
                confirmation_url=?,
                updated_at=CURRENT_TIMESTAMP
            WHERE order_id=?
            """,
            (
                invoice_id,
                str(invoice.get("status") or "NEW"),
                payment_url,
                order_id,
            ),
        )
        self.db.commit()
        return self._checkout_result(order_id)

    def create_manual_subscription_order(self, login):
        if not self.manual_billing_configured:
            raise BillingError("Sber payment is not configured")
        if not self.subscription_checkout_ready:
            raise BillingError("the VPN backend is not ready")

        normalized_login = (login or "").strip().lower()
        if not normalized_login or len(normalized_login) > 64:
            raise BillingError("invalid login")
        account = self.db.execute(
            "SELECT 1 FROM accounts WHERE login=?",
            (normalized_login,),
        ).fetchone()
        if not account:
            raise BillingError("account does not exist")

        reusable = self.db.execute(
            """
            SELECT order_id
            FROM subscription_orders
            WHERE login=?
              AND product='meshpro'
              AND plan_code='monthly'
              AND provider='sber_manual'
              AND status IN ('pending', 'customer_reported')
              AND created_at > DATETIME('now', '-12 hours')
            ORDER BY created_at DESC
            LIMIT 1
            """,
            (normalized_login,),
        ).fetchone()
        if reusable:
            return self._manual_order_result(reusable[0])

        order_id = str(uuid.uuid4())
        checkout_key = secrets.token_urlsafe(32)
        self.db.execute(
            """
            INSERT INTO subscription_orders(
                order_id,
                checkout_key,
                login,
                product,
                plan_code,
                duration_days,
                amount_value,
                currency,
                provider,
                status,
                confirmation_url
            )
            VALUES(?, ?, ?, 'meshpro', 'monthly', ?, ?, 'RUB',
                   'sber_manual', 'pending', ?)
            """,
            (
                order_id,
                checkout_key,
                normalized_login,
                max(1, int(MESHPRO_MONTHLY_DAYS)),
                self._monthly_price(),
                self._validated_sber_payment_url(),
            ),
        )
        self.db.commit()
        return self._manual_order_result(order_id)

    def manual_order_status(self, order_id, checkout_key):
        row = self.db.execute(
            """
            SELECT status
            FROM subscription_orders
            WHERE order_id=?
              AND checkout_key=?
              AND provider='sber_manual'
            """,
            ((order_id or "").strip(), (checkout_key or "").strip()),
        ).fetchone()
        if not row:
            raise BillingError("order not found")
        return {"status": row[0]}

    def mark_manual_order_submitted(self, order_id, checkout_key):
        row = self.db.execute(
            """
            SELECT status
            FROM subscription_orders
            WHERE order_id=?
              AND checkout_key=?
              AND provider='sber_manual'
            """,
            ((order_id or "").strip(), (checkout_key or "").strip()),
        ).fetchone()
        if not row:
            raise BillingError("order not found")
        if row[0] == "pending":
            self.db.execute(
                """
                UPDATE subscription_orders
                SET status='customer_reported', updated_at=CURRENT_TIMESTAMP
                WHERE order_id=? AND checkout_key=?
                """,
                ((order_id or "").strip(), (checkout_key or "").strip()),
            )
            self.db.commit()
        return self.manual_order_status(order_id, checkout_key)

    def list_manual_subscription_orders(self, status="awaiting", limit=50):
        normalized_status = (status or "awaiting").strip().lower()
        statuses = {
            "awaiting": ("pending", "customer_reported"),
            "pending": ("pending",),
            "reported": ("customer_reported",),
            "approved": ("succeeded",),
            "rejected": ("rejected",),
            "all": (),
        }
        if normalized_status not in statuses:
            raise BillingError("unknown order status")
        selected = statuses[normalized_status]
        where_status = ""
        parameters = []
        if selected:
            placeholders = ",".join("?" for _ in selected)
            where_status = f"AND status IN ({placeholders})"
            parameters.extend(selected)
        parameters.append(max(1, min(int(limit), 200)))
        rows = self.db.execute(
            f"""
            SELECT order_id,
                   login,
                   status,
                   amount_value,
                   currency,
                   duration_days,
                   created_at,
                   paid_at
            FROM subscription_orders
            WHERE provider='sber_manual'
              {where_status}
            ORDER BY created_at DESC
            LIMIT ?
            """,
            parameters,
        ).fetchall()
        return [
            {
                "order_id": row[0],
                "reference": self._manual_order_reference(row[0]),
                "login": row[1],
                "status": row[2],
                "amount_value": row[3],
                "currency": row[4],
                "duration_days": row[5],
                "created_at": row[6],
                "paid_at": row[7],
            }
            for row in rows
        ]

    def approve_manual_subscription_order(self, order_id):
        normalized_order_id = self._resolve_manual_order_id(order_id)
        row = self.db.execute(
            """
            SELECT login, product, plan_code, duration_days, status
            FROM subscription_orders
            WHERE order_id=? AND provider='sber_manual'
            """,
            (normalized_order_id,),
        ).fetchone()
        if not row:
            raise BillingError("manual order not found")
        if row[4] == "rejected":
            raise BillingError("manual order was rejected")

        subscription = self.grant_subscription(
            row[0],
            product=row[1],
            plan_code=row[2],
            days=row[3],
            provider="sber_manual",
            provider_subscription_id=normalized_order_id,
            provider_event_id=f"sber_manual:approved:{normalized_order_id}",
        )
        self.db.execute(
            """
            UPDATE subscription_orders
            SET status='succeeded',
                paid_at=COALESCE(paid_at, CURRENT_TIMESTAMP),
                updated_at=CURRENT_TIMESTAMP
            WHERE order_id=?
            """,
            (normalized_order_id,),
        )
        self.db.commit()
        return {
            "order": self._manual_order_admin_result(normalized_order_id),
            "subscription": subscription,
        }

    def reject_manual_subscription_order(self, order_id):
        normalized_order_id = self._resolve_manual_order_id(order_id)
        row = self.db.execute(
            """
            SELECT status
            FROM subscription_orders
            WHERE order_id=? AND provider='sber_manual'
            """,
            (normalized_order_id,),
        ).fetchone()
        if not row:
            raise BillingError("manual order not found")
        if row[0] == "succeeded":
            raise BillingError("approved order cannot be rejected")
        self.db.execute(
            """
            UPDATE subscription_orders
            SET status='rejected', updated_at=CURRENT_TIMESTAMP
            WHERE order_id=?
            """,
            (normalized_order_id,),
        )
        self.db.commit()
        return self._manual_order_admin_result(normalized_order_id)

    def _manual_order_result(self, order_id):
        row = self.db.execute(
            """
            SELECT order_id,
                   checkout_key,
                   login,
                   status,
                   confirmation_url,
                   amount_value,
                   currency,
                   duration_days
            FROM subscription_orders
            WHERE order_id=? AND provider='sber_manual'
            """,
            (order_id,),
        ).fetchone()
        if not row:
            raise BillingError("manual order not found")
        return {
            "order_id": row[0],
            "provider": "sber_manual",
            "checkout_key": row[1],
            "reference": self._manual_order_reference(row[0]),
            "login": row[2],
            "status": row[3],
            "confirmation_url": row[4],
            "amount_value": row[5],
            "currency": row[6],
            "duration_days": row[7],
        }

    def _manual_order_admin_result(self, order_id):
        orders = self.db.execute(
            """
            SELECT order_id,
                   login,
                   status,
                   amount_value,
                   currency,
                   duration_days,
                   created_at,
                   paid_at
            FROM subscription_orders
            WHERE order_id=? AND provider='sber_manual'
            """,
            (order_id,),
        ).fetchone()
        if not orders:
            raise BillingError("manual order not found")
        return {
            "order_id": orders[0],
            "reference": self._manual_order_reference(orders[0]),
            "login": orders[1],
            "status": orders[2],
            "amount_value": orders[3],
            "currency": orders[4],
            "duration_days": orders[5],
            "created_at": orders[6],
            "paid_at": orders[7],
        }

    def _manual_order_reference(self, order_id):
        return f"MP-{(order_id or '').replace('-', '')[:8].upper()}"

    def _resolve_manual_order_id(self, order_id_or_reference):
        value = (order_id_or_reference or "").strip()
        if not value:
            raise BillingError("manual order id is required")
        if value.upper().startswith("MP-"):
            prefix = value[3:].replace("-", "").strip().lower()
            if len(prefix) < 6 or any(
                character not in "0123456789abcdef" for character in prefix
            ):
                raise BillingError("invalid payment reference")
            rows = self.db.execute(
                """
                SELECT order_id
                FROM subscription_orders
                WHERE provider='sber_manual'
                  AND REPLACE(LOWER(order_id), '-', '') LIKE ?
                LIMIT 2
                """,
                (f"{prefix}%",),
            ).fetchall()
            if len(rows) != 1:
                raise BillingError("manual order reference is not unique")
            return rows[0][0]
        return value

    def _checkout_page_url(self, login=""):
        base_url = (SUBSCRIPTION_CHECKOUT_URL or "").strip()
        if not base_url:
            return ""
        parsed = urlparse(base_url)
        query = dict(parse_qsl(parsed.query, keep_blank_values=True))
        if login:
            query["login"] = login
        return urlunparse(parsed._replace(query=urlencode(query)))

    def _validated_sber_payment_url(self):
        value = (SBER_PAYMENT_URL or "").strip()
        if not value:
            return ""
        parsed = urlparse(value)
        if parsed.scheme != "https" or not parsed.netloc:
            raise BillingError("Sber payment URL must use HTTPS")
        return value

    async def process_lava_notification(self, notification):
        if not self.lava_billing_configured:
            raise BillingError("Lava billing is not configured")
        if not isinstance(notification, dict):
            raise BillingError("invalid notification")

        event_type = str(notification.get("eventType") or "").strip()
        supported_events = {
            "payment.success",
            "payment.failed",
            "subscription.recurring.payment.success",
            "subscription.recurring.payment.failed",
            "subscription.cancelled",
        }
        if event_type not in supported_events:
            return {
                "accepted": True,
                "ignored": True,
                "event": event_type,
            }

        contract_id = str(notification.get("contractId") or "").strip()
        parent_contract_id = str(
            notification.get("parentContractId") or ""
        ).strip()
        if not contract_id:
            raise BillingError("Lava contract id is missing")

        order = self._lava_order_for_notification(
            contract_id,
            parent_contract_id,
        )
        webhook_product_id = str(
            (notification.get("product") or {}).get("id") or ""
        ).strip()
        webhook_email = self._normalize_buyer_email(
            (notification.get("buyer") or {}).get("email")
        )
        if webhook_product_id != order[8]:
            raise BillingError("Lava webhook product mismatch")
        if webhook_email != order[7]:
            raise BillingError("Lava webhook buyer mismatch")

        event_id = f"lava:{event_type}:{contract_id}"
        if event_type == "subscription.cancelled":
            subscription_id = order[10]
            subscription = await self._lava_request(
                "GET",
                f"/api/v1/subscriptions/{subscription_id}",
            )
            self._verify_lava_subscription(subscription, order)
            status = self.mark_subscription_cancel_at_period_end(
                order[1],
                product=order[2],
                provider="lava",
                provider_subscription_id=subscription_id,
                provider_event_id=event_id,
            )
            self.db.execute(
                """
                UPDATE subscription_orders
                SET status='cancelled', updated_at=CURRENT_TIMESTAMP
                WHERE order_id=?
                """,
                (order[0],),
            )
            self.db.commit()
            return {"accepted": True, "subscription": status}

        invoice = await self._lava_request(
            "GET",
            f"/api/v2/invoices/{contract_id}",
        )
        expected_success = event_type.endswith("success")
        recurring = event_type.startswith("subscription.recurring")
        self._verify_lava_invoice(
            invoice,
            order,
            contract_id,
            parent_contract_id,
            expected_success=expected_success,
            recurring=recurring,
        )

        if expected_success:
            subscription = self.grant_subscription(
                order[1],
                product=order[2],
                plan_code=order[3],
                days=order[4],
                provider="lava",
                provider_subscription_id=order[10],
                provider_event_id=event_id,
            )
            self.db.execute(
                """
                UPDATE subscription_orders
                SET status=?,
                    paid_at=COALESCE(paid_at, CURRENT_TIMESTAMP),
                    updated_at=CURRENT_TIMESTAMP
                WHERE order_id=?
                """,
                ("active" if recurring else "succeeded", order[0]),
            )
            self.db.commit()
            return {"accepted": True, "subscription": subscription}

        self.record_subscription_event_once(
            order[1],
            order[2],
            "renewal_failed" if recurring else "payment_failed",
            {
                "provider": "lava",
                "contract_id": contract_id,
                "parent_contract_id": parent_contract_id,
                "error": str(notification.get("errorMessage") or ""),
            },
            event_id,
        )
        self.db.execute(
            """
            UPDATE subscription_orders
            SET status=?, updated_at=CURRENT_TIMESTAMP
            WHERE order_id=?
            """,
            ("renewal_failed" if recurring else "failed", order[0]),
        )
        self.db.commit()
        return {"accepted": True, "failed": True, "recurring": recurring}

    def _lava_order_for_notification(self, contract_id, parent_contract_id):
        candidates = [contract_id]
        if parent_contract_id:
            candidates.append(parent_contract_id)
        placeholders = ",".join("?" for _ in candidates)
        row = self.db.execute(
            f"""
            SELECT order_id,
                   login,
                   product,
                   plan_code,
                   duration_days,
                   amount_value,
                   currency,
                   buyer_email,
                   provider_product_id,
                   provider_offer_id,
                   provider_payment_id
            FROM subscription_orders
            WHERE provider='lava'
              AND provider_payment_id IN ({placeholders})
            ORDER BY CASE WHEN provider_payment_id=? THEN 0 ELSE 1 END
            LIMIT 1
            """,
            (*candidates, parent_contract_id or contract_id),
        ).fetchone()
        if not row:
            raise BillingError("Lava payment does not belong to a local order")
        if parent_contract_id and row[10] != parent_contract_id:
            raise BillingError("Lava parent contract mismatch")
        if not parent_contract_id and row[10] != contract_id:
            raise BillingError("Lava contract mismatch")
        return row

    def _verify_lava_invoice(
        self,
        invoice,
        order,
        contract_id,
        parent_contract_id,
        expected_success,
        recurring,
    ):
        if str(invoice.get("id") or "").strip() != contract_id:
            raise BillingError("Lava verification returned another invoice")
        invoice_status = str(invoice.get("status") or "").upper()
        expected_status = "COMPLETED" if expected_success else "FAILED"
        if invoice_status != expected_status:
            raise BillingError(
                f"Lava invoice is {invoice_status or 'UNKNOWN'}, "
                f"expected {expected_status}"
            )
        invoice_type = str(invoice.get("type") or "").upper()
        expected_type = (
            "SUBSCRIPTION_RENEWAL"
            if recurring
            else "SUBSCRIPTION_FIRST_INVOICE"
        )
        if invoice_type != expected_type:
            raise BillingError("Lava invoice type mismatch")

        product = invoice.get("product") or {}
        if str(product.get("id") or "").strip() != order[8]:
            raise BillingError("Lava invoice product mismatch")
        offer = product.get("offer") or invoice.get("offer") or {}
        verified_offer_id = str(offer.get("id") or "").strip()
        if verified_offer_id and verified_offer_id != order[9]:
            raise BillingError("Lava invoice offer mismatch")

        buyer = invoice.get("buyer") or {}
        if self._normalize_buyer_email(buyer.get("email")) != order[7]:
            raise BillingError("Lava invoice buyer mismatch")
        amount = (
            invoice.get("receipt")
            or invoice.get("amountTotal")
            or invoice.get("amount")
            or {}
        )
        amount_value = (
            amount.get("amount")
            if isinstance(amount, dict)
            else None
        )
        if isinstance(amount, dict) and amount_value is None:
            amount_value = amount.get("value", amount.get("total"))
        if self._money(amount_value) != self._money(order[5]):
            raise BillingError("Lava invoice amount mismatch")
        if str(amount.get("currency") or "").upper() != order[6].upper():
            raise BillingError("Lava invoice currency mismatch")

        client_utm = invoice.get("clientUtm") or {}
        campaign = str(client_utm.get("utm_campaign") or "").strip()
        if campaign and campaign != order[0]:
            raise BillingError("Lava invoice order marker mismatch")
        if recurring:
            parent_invoice = invoice.get("parentInvoice") or {}
            verified_parent = str(
                invoice.get("parentInvoiceId")
                or parent_invoice.get("id")
                or ""
            ).strip()
            if verified_parent != parent_contract_id:
                raise BillingError("Lava renewal parent mismatch")

    def _verify_lava_subscription(self, subscription, order):
        subscription_id = str(subscription.get("id") or "").strip()
        if subscription_id and subscription_id != order[10]:
            raise BillingError("Lava subscription id mismatch")
        status = str(
            subscription.get("subscriptionStatus")
            or subscription.get("status")
            or ""
        ).upper()
        if status not in {"CANCELLED", "CANCELED"}:
            raise BillingError("Lava subscription is not cancelled")
        product = subscription.get("product") or {}
        if str(product.get("id") or "").strip() != order[8]:
            raise BillingError("Lava subscription product mismatch")
        buyer = subscription.get("buyer") or {}
        if self._normalize_buyer_email(buyer.get("email")) != order[7]:
            raise BillingError("Lava subscription buyer mismatch")

    async def process_yookassa_notification(self, notification):
        if not self.yookassa_billing_configured:
            raise BillingError("billing is not configured")
        if not isinstance(notification, dict):
            raise BillingError("invalid notification")
        event = str(notification.get("event") or "").strip()
        payment_id = str(
            (notification.get("object") or {}).get("id") or ""
        ).strip()
        if event not in {"payment.succeeded", "payment.canceled"}:
            return {"accepted": True, "ignored": True, "event": event}
        if not payment_id:
            raise BillingError("payment id is missing")

        payment = await self._yookassa_request(
            "GET",
            f"/payments/{payment_id}",
        )
        if str(payment.get("id") or "") != payment_id:
            raise BillingError("payment verification returned a different object")
        if event == "payment.succeeded":
            if payment.get("status") != "succeeded" or payment.get("paid") is not True:
                raise BillingError("payment is not succeeded")
            status = self._apply_verified_payment(payment, event)
            return {"accepted": True, "subscription": status}

        if payment.get("status") != "canceled":
            raise BillingError("payment is not canceled")
        self.db.execute(
            """
            UPDATE subscription_orders
            SET status='canceled', updated_at=CURRENT_TIMESTAMP
            WHERE provider='yookassa' AND provider_payment_id=?
            """,
            (payment_id,),
        )
        self.db.commit()
        return {"accepted": True, "canceled": True}

    def _apply_verified_payment(self, payment, event):
        payment_id = str(payment.get("id") or "").strip()
        metadata = payment.get("metadata") or {}
        order_id = str(metadata.get("mesh_order_id") or "").strip()
        row = self.db.execute(
            """
            SELECT order_id,
                   login,
                   product,
                   plan_code,
                   duration_days,
                   amount_value,
                   currency
            FROM subscription_orders
            WHERE provider='yookassa'
              AND (provider_payment_id=? OR order_id=?)
            ORDER BY CASE WHEN provider_payment_id=? THEN 0 ELSE 1 END
            LIMIT 1
            """,
            (payment_id, order_id, payment_id),
        ).fetchone()
        if not row:
            raise BillingError("payment does not belong to a local order")
        if order_id != row[0]:
            raise BillingError("payment order metadata mismatch")
        if str(metadata.get("login") or "").strip().lower() != row[1]:
            raise BillingError("payment login metadata mismatch")
        if str(metadata.get("product") or "").strip().lower() != row[2]:
            raise BillingError("payment product metadata mismatch")
        if str(metadata.get("plan_code") or "").strip().lower() != row[3]:
            raise BillingError("payment plan metadata mismatch")
        amount = payment.get("amount") or {}
        if self._money(amount.get("value")) != self._money(row[5]):
            raise BillingError("payment amount mismatch")
        if str(amount.get("currency") or "").upper() != row[6].upper():
            raise BillingError("payment currency mismatch")

        provider_event_id = f"yookassa:{event}:{payment_id}"
        status = self.grant_subscription(
            row[1],
            product=row[2],
            plan_code=row[3],
            days=row[4],
            provider="yookassa",
            provider_subscription_id=payment_id,
            provider_event_id=provider_event_id,
        )
        payment_method = payment.get("payment_method") or {}
        payment_method_id = ""
        if payment_method.get("saved") is True:
            payment_method_id = str(payment_method.get("id") or "").strip()
        self.db.execute(
            """
            UPDATE subscription_orders
            SET provider_payment_id=?,
                status='succeeded',
                payment_method_id=?,
                paid_at=COALESCE(paid_at, CURRENT_TIMESTAMP),
                updated_at=CURRENT_TIMESTAMP
            WHERE order_id=?
            """,
            (payment_id, payment_method_id, row[0]),
        )
        self.db.commit()
        return status

    def _checkout_result(self, order_id):
        row = self.db.execute(
            """
            SELECT order_id,
                   status,
                   confirmation_url,
                   amount_value,
                   currency,
                   duration_days,
                   provider,
                   buyer_email
            FROM subscription_orders
            WHERE order_id=?
            """,
            (order_id,),
        ).fetchone()
        if not row:
            raise BillingError("checkout order not found")
        return {
            "order_id": row[0],
            "status": row[1],
            "confirmation_url": row[2],
            "amount_value": row[3],
            "currency": row[4],
            "duration_days": row[5],
            "provider": row[6],
            "buyer_email": row[7],
        }

    async def _lava_request(self, method, path, payload=None):
        if aiohttp is None:
            raise BillingError("aiohttp is required for Lava billing")
        headers = {
            "Accept": "application/json",
            "X-Api-Key": LAVA_API_KEY,
        }
        timeout = aiohttp.ClientTimeout(total=20)
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.request(
                method,
                f"{LAVA_API_URL}{path}",
                json=payload,
                headers=headers,
            ) as response:
                body = await response.text()
                try:
                    decoded = json.loads(body) if body else {}
                except json.JSONDecodeError as error:
                    raise BillingError(
                        f"Lava returned invalid JSON ({response.status})"
                    ) from error
                if response.status < 200 or response.status >= 300:
                    description = (
                        decoded.get("message")
                        or decoded.get("error")
                        or decoded.get("code")
                    )
                    raise BillingError(
                        f"Lava request failed ({response.status}): "
                        f"{description or 'unknown error'}"
                    )
                if not isinstance(decoded, dict):
                    raise BillingError("Lava returned an invalid object")
                return decoded

    async def _yookassa_request(
        self,
        method,
        path,
        payload=None,
        idempotence_key=None,
    ):
        if aiohttp is None:
            raise BillingError("aiohttp is required for YooKassa billing")
        headers = {"Accept": "application/json"}
        if idempotence_key:
            headers["Idempotence-Key"] = idempotence_key
        timeout = aiohttp.ClientTimeout(total=15)
        auth = aiohttp.BasicAuth(YOOKASSA_SHOP_ID, YOOKASSA_SECRET_KEY)
        async with aiohttp.ClientSession(timeout=timeout, auth=auth) as session:
            async with session.request(
                method,
                f"{YOOKASSA_API_URL}{path}",
                json=payload,
                headers=headers,
            ) as response:
                body = await response.text()
                try:
                    decoded = json.loads(body) if body else {}
                except json.JSONDecodeError as error:
                    raise BillingError(
                        f"YooKassa returned invalid JSON ({response.status})"
                    ) from error
                if response.status < 200 or response.status >= 300:
                    description = decoded.get("description") or decoded.get("code")
                    raise BillingError(
                        f"YooKassa request failed ({response.status}): {description}"
                    )
                if not isinstance(decoded, dict):
                    raise BillingError("YooKassa returned an invalid object")
                return decoded

    def _monthly_price(self):
        value = self._money(MESHPRO_MONTHLY_PRICE)
        if value <= 0:
            raise BillingError("subscription price must be positive")
        return f"{value:.2f}"

    def _normalize_buyer_email(self, value):
        normalized = str(value or "").strip().lower()
        if not normalized:
            return ""
        if len(normalized) > 254 or re.fullmatch(
            r"[^@\s]+@[^@\s]+\.[^@\s]+",
            normalized,
        ) is None:
            raise BillingError("invalid email")
        return normalized

    def _validated_https_url(self, value):
        normalized = str(value or "").strip()
        parsed = urlparse(normalized)
        if parsed.scheme != "https" or not parsed.netloc:
            return ""
        return normalized

    def _money(self, value):
        try:
            return Decimal(str(value)).quantize(Decimal("0.01"))
        except (InvalidOperation, ValueError) as error:
            raise BillingError("invalid monetary value") from error
