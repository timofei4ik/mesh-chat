class PostgresBillingRepository:
    """PostgreSQL implementation of the billing-order repository contract."""

    def __init__(self, connection):
        self._connection = connection

    def _one(self, query, parameters=()):
        with self._connection.cursor() as cursor:
            cursor.execute(query, parameters)
            return cursor.fetchone()

    def _all(self, query, parameters=()):
        with self._connection.cursor() as cursor:
            cursor.execute(query, parameters)
            return cursor.fetchall()

    def _execute(self, query, parameters=()):
        with self._connection.cursor() as cursor:
            cursor.execute(query, parameters)

    def reusable_order(
        self,
        login,
        product,
        plan_code,
        provider,
        statuses,
        max_age_minutes,
        buyer_email="",
    ):
        email_clause = " AND buyer_email=%s" if buyer_email else ""
        parameters = [login, product, plan_code, provider, list(statuses)]
        if buyer_email:
            parameters.append(buyer_email)
        parameters.append(max(1, int(max_age_minutes)))
        return self._one(
            f"""
            SELECT order_id
            FROM subscription_orders
            WHERE login=%s AND product=%s AND plan_code=%s AND provider=%s
              AND status=ANY(%s)
              AND confirmation_url != ''
              {email_clause}
              AND created_at > CURRENT_TIMESTAMP - (%s * INTERVAL '1 minute')
            ORDER BY created_at DESC
            LIMIT 1
            """,
            parameters,
        )

    def order_by_checkout_key(self, checkout_key):
        return self._one(
            """
            SELECT order_id, provider_payment_id, status, confirmation_url
            FROM subscription_orders WHERE checkout_key=%s
            """,
            (checkout_key,),
        )

    def create_order(self, order):
        self._execute(
            """
            INSERT INTO subscription_orders(
                order_id, checkout_key, login, product, plan_code,
                duration_days, amount_value, currency, provider, status,
                confirmation_url, buyer_email, provider_product_id,
                provider_offer_id
            )
            VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
            """,
            (
                order["order_id"], order["checkout_key"], order["login"],
                order["product"], order["plan_code"],
                order["duration_days"], order["amount_value"],
                order.get("currency", "RUB"), order["provider"],
                order.get("status", "creating"),
                order.get("confirmation_url", ""),
                order.get("buyer_email", ""),
                order.get("provider_product_id", ""),
                order.get("provider_offer_id", ""),
            ),
        )

    def set_checkout_error(self, order_id):
        self.set_order_status(order_id, "checkout_error")

    def set_provider_checkout(
        self, order_id, payment_id, status, confirmation_url
    ):
        self._execute(
            """
            UPDATE subscription_orders
            SET provider_payment_id=%s, status=%s, confirmation_url=%s,
                updated_at=CURRENT_TIMESTAMP
            WHERE order_id=%s
            """,
            (payment_id, status, confirmation_url, order_id),
        )

    def checkout_result(self, order_id):
        return self._one(
            """
            SELECT order_id, status, confirmation_url, amount_value,
                   currency, duration_days, provider, buyer_email
            FROM subscription_orders WHERE order_id=%s
            """,
            (order_id,),
        )

    def manual_status(self, order_id, checkout_key):
        return self._one(
            """
            SELECT status FROM subscription_orders
            WHERE order_id=%s AND checkout_key=%s AND provider='sber_manual'
            """,
            (order_id, checkout_key),
        )

    def mark_manual_submitted(self, order_id, checkout_key):
        self._execute(
            """
            UPDATE subscription_orders
            SET status='customer_reported', updated_at=CURRENT_TIMESTAMP
            WHERE order_id=%s AND checkout_key=%s AND status='pending'
            """,
            (order_id, checkout_key),
        )

    def list_manual_orders(self, statuses, limit):
        if statuses:
            return self._all(
                """
                SELECT order_id, login, status, amount_value, currency,
                       duration_days, created_at, paid_at
                FROM subscription_orders
                WHERE provider='sber_manual' AND status=ANY(%s)
                ORDER BY created_at DESC LIMIT %s
                """,
                (list(statuses), max(1, min(int(limit), 200))),
            )
        return self._all(
            """
            SELECT order_id, login, status, amount_value, currency,
                   duration_days, created_at, paid_at
            FROM subscription_orders
            WHERE provider='sber_manual'
            ORDER BY created_at DESC LIMIT %s
            """,
            (max(1, min(int(limit), 200)),),
        )

    def manual_approval_row(self, order_id):
        return self._one(
            """
            SELECT login, product, plan_code, duration_days, status
            FROM subscription_orders
            WHERE order_id=%s AND provider='sber_manual'
            """,
            (order_id,),
        )

    def manual_result(self, order_id):
        return self._one(
            """
            SELECT order_id, checkout_key, login, status, confirmation_url,
                   amount_value, currency, duration_days
            FROM subscription_orders
            WHERE order_id=%s AND provider='sber_manual'
            """,
            (order_id,),
        )

    def manual_admin_result(self, order_id):
        return self._one(
            """
            SELECT order_id, login, status, amount_value, currency,
                   duration_days, created_at, paid_at
            FROM subscription_orders
            WHERE order_id=%s AND provider='sber_manual'
            """,
            (order_id,),
        )

    def manual_ids_by_prefix(self, prefix):
        rows = self._all(
            """
            SELECT order_id FROM subscription_orders
            WHERE provider='sber_manual'
              AND REPLACE(LOWER(order_id), '-', '') LIKE %s
            LIMIT 2
            """,
            (f"{prefix}%",),
        )
        return [row[0] for row in rows]

    def set_order_status(self, order_id, status, paid=False):
        paid_expression = (
            "paid_at=COALESCE(paid_at, CURRENT_TIMESTAMP),"
            if paid else ""
        )
        self._execute(
            f"""
            UPDATE subscription_orders
            SET status=%s, {paid_expression} updated_at=CURRENT_TIMESTAMP
            WHERE order_id=%s
            """,
            (status, order_id),
        )

    def lava_notification_order(
        self, contract_ids, preferred_contract_id
    ):
        return self._one(
            """
            SELECT order_id, login, product, plan_code, duration_days,
                   amount_value, currency, buyer_email, provider_product_id,
                   provider_offer_id, provider_payment_id
            FROM subscription_orders
            WHERE provider='lava' AND provider_payment_id=ANY(%s)
            ORDER BY CASE WHEN provider_payment_id=%s THEN 0 ELSE 1 END
            LIMIT 1
            """,
            (list(contract_ids), preferred_contract_id),
        )

    def yookassa_payment_order(self, payment_id, order_id):
        return self._one(
            """
            SELECT order_id, login, product, plan_code, duration_days,
                   amount_value, currency
            FROM subscription_orders
            WHERE provider='yookassa'
              AND (provider_payment_id=%s OR order_id=%s)
            ORDER BY CASE WHEN provider_payment_id=%s THEN 0 ELSE 1 END
            LIMIT 1
            """,
            (payment_id, order_id, payment_id),
        )

    def cancel_yookassa_payment(self, payment_id):
        self._execute(
            """
            UPDATE subscription_orders
            SET status='canceled', updated_at=CURRENT_TIMESTAMP
            WHERE provider='yookassa' AND provider_payment_id=%s
            """,
            (payment_id,),
        )

    def mark_yookassa_succeeded(
        self, order_id, payment_id, payment_method_id
    ):
        self._execute(
            """
            UPDATE subscription_orders
            SET provider_payment_id=%s, status='succeeded',
                payment_method_id=%s,
                paid_at=COALESCE(paid_at, CURRENT_TIMESTAMP),
                updated_at=CURRENT_TIMESTAMP
            WHERE order_id=%s
            """,
            (payment_id, payment_method_id, order_id),
        )
