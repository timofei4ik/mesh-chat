class SQLiteBillingRepository:
    def __init__(self, connection):
        self._connection = connection

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
        placeholders = ",".join("?" for _ in statuses)
        email_clause = " AND buyer_email=?" if buyer_email else ""
        parameters = [
            login,
            product,
            plan_code,
            provider,
            *statuses,
        ]
        if buyer_email:
            parameters.append(buyer_email)
        parameters.append(f"-{max(1, int(max_age_minutes))} minutes")
        return self._connection.execute(
            f"""
            SELECT order_id
            FROM subscription_orders
            WHERE login=?
              AND product=?
              AND plan_code=?
              AND provider=?
              AND status IN ({placeholders})
              AND confirmation_url != ''
              {email_clause}
              AND created_at > DATETIME('now', ?)
            ORDER BY created_at DESC
            LIMIT 1
            """,
            parameters,
        ).fetchone()

    def order_by_checkout_key(self, checkout_key):
        return self._connection.execute(
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

    def create_order(self, order):
        self._connection.execute(
            """
            INSERT INTO subscription_orders(
                order_id, checkout_key, login, product, plan_code,
                duration_days, amount_value, currency, provider, status,
                confirmation_url, buyer_email, provider_product_id,
                provider_offer_id
            )
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            (
                order["order_id"],
                order["checkout_key"],
                order["login"],
                order["product"],
                order["plan_code"],
                order["duration_days"],
                order["amount_value"],
                order.get("currency", "RUB"),
                order["provider"],
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
        self,
        order_id,
        payment_id,
        status,
        confirmation_url,
    ):
        self._connection.execute(
            """
            UPDATE subscription_orders
            SET provider_payment_id=?,
                status=?,
                confirmation_url=?,
                updated_at=CURRENT_TIMESTAMP
            WHERE order_id=?
            """,
            (payment_id, status, confirmation_url, order_id),
        )

    def checkout_result(self, order_id):
        return self._connection.execute(
            """
            SELECT order_id, status, confirmation_url, amount_value,
                   currency, duration_days, provider, buyer_email
            FROM subscription_orders
            WHERE order_id=?
            """,
            (order_id,),
        ).fetchone()

    def manual_status(self, order_id, checkout_key):
        return self._connection.execute(
            """
            SELECT status
            FROM subscription_orders
            WHERE order_id=? AND checkout_key=? AND provider='sber_manual'
            """,
            (order_id, checkout_key),
        ).fetchone()

    def mark_manual_submitted(self, order_id, checkout_key):
        self._connection.execute(
            """
            UPDATE subscription_orders
            SET status='customer_reported', updated_at=CURRENT_TIMESTAMP
            WHERE order_id=? AND checkout_key=? AND status='pending'
            """,
            (order_id, checkout_key),
        )

    def list_manual_orders(self, statuses, limit):
        status_clause = ""
        parameters = []
        if statuses:
            placeholders = ",".join("?" for _ in statuses)
            status_clause = f"AND status IN ({placeholders})"
            parameters.extend(statuses)
        parameters.append(max(1, min(int(limit), 200)))
        return self._connection.execute(
            f"""
            SELECT order_id, login, status, amount_value, currency,
                   duration_days, created_at, paid_at
            FROM subscription_orders
            WHERE provider='sber_manual' {status_clause}
            ORDER BY created_at DESC
            LIMIT ?
            """,
            parameters,
        ).fetchall()

    def manual_approval_row(self, order_id):
        return self._connection.execute(
            """
            SELECT login, product, plan_code, duration_days, status
            FROM subscription_orders
            WHERE order_id=? AND provider='sber_manual'
            """,
            (order_id,),
        ).fetchone()

    def manual_result(self, order_id):
        return self._connection.execute(
            """
            SELECT order_id, checkout_key, login, status, confirmation_url,
                   amount_value, currency, duration_days
            FROM subscription_orders
            WHERE order_id=? AND provider='sber_manual'
            """,
            (order_id,),
        ).fetchone()

    def manual_admin_result(self, order_id):
        return self._connection.execute(
            """
            SELECT order_id, login, status, amount_value, currency,
                   duration_days, created_at, paid_at
            FROM subscription_orders
            WHERE order_id=? AND provider='sber_manual'
            """,
            (order_id,),
        ).fetchone()

    def manual_ids_by_prefix(self, prefix):
        return [
            row[0]
            for row in self._connection.execute(
                """
                SELECT order_id
                FROM subscription_orders
                WHERE provider='sber_manual'
                  AND REPLACE(LOWER(order_id), '-', '') LIKE ?
                LIMIT 2
                """,
                (f"{prefix}%",),
            ).fetchall()
        ]

    def set_order_status(self, order_id, status, paid=False):
        paid_expression = (
            "paid_at=COALESCE(paid_at, CURRENT_TIMESTAMP),"
            if paid
            else ""
        )
        self._connection.execute(
            f"""
            UPDATE subscription_orders
            SET status=?, {paid_expression} updated_at=CURRENT_TIMESTAMP
            WHERE order_id=?
            """,
            (status, order_id),
        )

    def lava_notification_order(
        self,
        contract_ids,
        preferred_contract_id,
    ):
        placeholders = ",".join("?" for _ in contract_ids)
        return self._connection.execute(
            f"""
            SELECT order_id, login, product, plan_code, duration_days,
                   amount_value, currency, buyer_email, provider_product_id,
                   provider_offer_id, provider_payment_id
            FROM subscription_orders
            WHERE provider='lava'
              AND provider_payment_id IN ({placeholders})
            ORDER BY CASE WHEN provider_payment_id=? THEN 0 ELSE 1 END
            LIMIT 1
            """,
            (*contract_ids, preferred_contract_id),
        ).fetchone()

    def yookassa_payment_order(self, payment_id, order_id):
        return self._connection.execute(
            """
            SELECT order_id, login, product, plan_code, duration_days,
                   amount_value, currency
            FROM subscription_orders
            WHERE provider='yookassa'
              AND (provider_payment_id=? OR order_id=?)
            ORDER BY CASE WHEN provider_payment_id=? THEN 0 ELSE 1 END
            LIMIT 1
            """,
            (payment_id, order_id, payment_id),
        ).fetchone()

    def cancel_yookassa_payment(self, payment_id):
        self._connection.execute(
            """
            UPDATE subscription_orders
            SET status='canceled', updated_at=CURRENT_TIMESTAMP
            WHERE provider='yookassa' AND provider_payment_id=?
            """,
            (payment_id,),
        )

    def mark_yookassa_succeeded(
        self,
        order_id,
        payment_id,
        payment_method_id,
    ):
        self._connection.execute(
            """
            UPDATE subscription_orders
            SET provider_payment_id=?,
                status='succeeded',
                payment_method_id=?,
                paid_at=COALESCE(paid_at, CURRENT_TIMESTAMP),
                updated_at=CURRENT_TIMESTAMP
            WHERE order_id=?
            """,
            (payment_id, payment_method_id, order_id),
        )
