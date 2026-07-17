import copy
import tempfile
import unittest
from pathlib import Path

from server import server_billing, server_storage, server_subscription


class BillingRelay(
    server_storage.ServerStorageMixin,
    server_billing.ServerBillingMixin,
    server_subscription.ServerSubscriptionMixin,
):
    def __init__(self):
        self.payments = {}
        self.lava_invoices = {}
        self.lava_subscriptions = {}
        self.db = self.open_db()

    async def _yookassa_request(
        self,
        method,
        path,
        payload=None,
        idempotence_key=None,
    ):
        if method == "POST" and path == "/payments":
            payment_id = f"payment-{len(self.payments) + 1}"
            payment = {
                "id": payment_id,
                "status": "pending",
                "paid": False,
                "amount": copy.deepcopy(payload["amount"]),
                "metadata": copy.deepcopy(payload["metadata"]),
                "confirmation": {
                    "type": "redirect",
                    "confirmation_url": f"https://pay.test/{payment_id}",
                },
            }
            self.payments[payment_id] = payment
            return copy.deepcopy(payment)
        if method == "GET" and path.startswith("/payments/"):
            return copy.deepcopy(self.payments[path.rsplit("/", 1)[-1]])
        raise AssertionError((method, path, payload, idempotence_key))

    async def _lava_request(self, method, path, payload=None):
        if method == "POST" and path == "/api/v3/invoice":
            invoice_id = f"lava-invoice-{len(self.lava_invoices) + 1}"
            self.lava_invoices[invoice_id] = {
                "id": invoice_id,
                "type": "SUBSCRIPTION_FIRST_INVOICE",
                "status": "NEW",
                "receipt": {"amount": "199.00", "currency": "RUB"},
                "buyer": {"email": payload["email"]},
                "product": {
                    "id": server_billing.LAVA_PRODUCT_ID,
                    "offer": {"id": server_billing.LAVA_OFFER_ID},
                },
                "clientUtm": copy.deepcopy(payload["clientUtm"]),
            }
            self.lava_subscriptions[invoice_id] = {
                "id": invoice_id,
                "subscriptionStatus": "ACTIVE",
                "buyer": {"email": payload["email"]},
                "product": {"id": server_billing.LAVA_PRODUCT_ID},
            }
            return {
                "id": invoice_id,
                "status": "NEW",
                "amountTotal": {"amount": "199.00", "currency": "RUB"},
                "paymentUrl": f"https://pay.lava.test/{invoice_id}",
            }
        if method == "GET" and path.startswith("/api/v2/invoices/"):
            return copy.deepcopy(
                self.lava_invoices[path.rsplit("/", 1)[-1]]
            )
        if method == "GET" and path.startswith("/api/v1/subscriptions/"):
            return copy.deepcopy(
                self.lava_subscriptions[path.rsplit("/", 1)[-1]]
            )
        raise AssertionError((method, path, payload))


class BillingTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.previous_db_path = server_storage.DB_PATH
        self.previous_shop_id = server_billing.YOOKASSA_SHOP_ID
        self.previous_secret = server_billing.YOOKASSA_SECRET_KEY
        self.previous_webhook_secret = server_billing.YOOKASSA_WEBHOOK_SECRET
        self.previous_lava_values = {
            name: getattr(server_billing, name)
            for name in (
                "LAVA_API_KEY",
                "LAVA_WEBHOOK_KEY",
                "LAVA_PRODUCT_ID",
                "LAVA_OFFER_ID",
            )
        }
        self.previous_price = server_billing.MESHPRO_MONTHLY_PRICE
        self.previous_days = server_billing.MESHPRO_MONTHLY_DAYS
        self.previous_sber_url = server_billing.SBER_PAYMENT_URL
        self.previous_checkout_url = server_billing.SUBSCRIPTION_CHECKOUT_URL
        self.previous_wireguard_enabled = server_billing.WIREGUARD_ENABLED
        self.previous_wireguard_endpoint = server_billing.WIREGUARD_ENDPOINT
        server_storage.DB_PATH = Path(self.temp_dir.name) / "server.db"
        server_billing.YOOKASSA_SHOP_ID = "test-shop"
        server_billing.YOOKASSA_SECRET_KEY = "test-secret"
        server_billing.YOOKASSA_WEBHOOK_SECRET = "test-webhook-secret"
        server_billing.LAVA_API_KEY = ""
        server_billing.LAVA_WEBHOOK_KEY = ""
        server_billing.LAVA_PRODUCT_ID = ""
        server_billing.LAVA_OFFER_ID = ""
        server_billing.MESHPRO_MONTHLY_PRICE = "199.00"
        server_billing.MESHPRO_MONTHLY_DAYS = 30
        server_billing.SBER_PAYMENT_URL = ""
        server_billing.SUBSCRIPTION_CHECKOUT_URL = ""
        server_billing.WIREGUARD_ENABLED = True
        server_billing.WIREGUARD_ENDPOINT = "vpn.test:51820"
        self.relay = BillingRelay()
        self.relay.db.execute(
            """
            INSERT INTO accounts(
                login,
                password_salt,
                password_hash,
                display_name
            )
            VALUES('subscriber', 'salt', 'hash', 'Subscriber')
            """
        )
        self.relay.db.commit()

    async def asyncTearDown(self):
        self.relay.db.close()
        server_storage.DB_PATH = self.previous_db_path
        server_billing.YOOKASSA_SHOP_ID = self.previous_shop_id
        server_billing.YOOKASSA_SECRET_KEY = self.previous_secret
        server_billing.YOOKASSA_WEBHOOK_SECRET = self.previous_webhook_secret
        for name, value in self.previous_lava_values.items():
            setattr(server_billing, name, value)
        server_billing.MESHPRO_MONTHLY_PRICE = self.previous_price
        server_billing.MESHPRO_MONTHLY_DAYS = self.previous_days
        server_billing.SBER_PAYMENT_URL = self.previous_sber_url
        server_billing.SUBSCRIPTION_CHECKOUT_URL = self.previous_checkout_url
        server_billing.WIREGUARD_ENABLED = self.previous_wireguard_enabled
        server_billing.WIREGUARD_ENDPOINT = self.previous_wireguard_endpoint
        self.temp_dir.cleanup()

    def enable_lava(self):
        server_billing.LAVA_API_KEY = "lava-outgoing-key"
        server_billing.LAVA_WEBHOOK_KEY = "lava-incoming-key"
        server_billing.LAVA_PRODUCT_ID = "product-meshpro"
        server_billing.LAVA_OFFER_ID = "offer-monthly"
        server_billing.SUBSCRIPTION_CHECKOUT_URL = (
            "https://mesh.example/meshpro/"
        )

    async def test_checkout_is_blocked_without_vpn_backend(self):
        server_billing.WIREGUARD_ENABLED = False
        with self.assertRaises(server_billing.BillingError):
            await self.relay.create_subscription_checkout(
                "subscriber",
                "device-a",
                "request-disabled-vpn",
            )
        self.assertFalse(
            self.relay.subscription_status("subscriber")[
                "checkout_available"
            ]
        )

    async def test_verified_payment_grants_once(self):
        checkout = await self.relay.create_subscription_checkout(
            "subscriber",
            "device-a",
            "request-a",
        )
        self.assertEqual("pending", checkout["status"])
        self.assertEqual("199.00", checkout["amount_value"])
        repeated_checkout = await self.relay.create_subscription_checkout(
            "subscriber",
            "device-a",
            "request-a-second-tap",
        )
        self.assertEqual(checkout["order_id"], repeated_checkout["order_id"])
        self.assertEqual(1, len(self.relay.payments))
        payment_id = next(iter(self.relay.payments))
        payment = self.relay.payments[payment_id]
        payment["status"] = "succeeded"
        payment["paid"] = True

        result = await self.relay.process_yookassa_notification(
            {
                "type": "notification",
                "event": "payment.succeeded",
                "object": {"id": payment_id},
            }
        )
        self.assertTrue(result["subscription"]["active"])
        self.assertEqual("meshpro", result["subscription"]["product"])
        first_end = result["subscription"]["current_period_end"]

        duplicate = await self.relay.process_yookassa_notification(
            {
                "type": "notification",
                "event": "payment.succeeded",
                "object": {"id": payment_id},
            }
        )
        self.assertEqual(
            first_end,
            duplicate["subscription"]["current_period_end"],
        )

    async def test_amount_mismatch_is_rejected(self):
        await self.relay.create_subscription_checkout(
            "subscriber",
            "device-a",
            "request-b",
        )
        payment_id = next(iter(self.relay.payments))
        payment = self.relay.payments[payment_id]
        payment["status"] = "succeeded"
        payment["paid"] = True
        payment["amount"]["value"] = "1.00"

        with self.assertRaises(server_billing.BillingError):
            await self.relay.process_yookassa_notification(
                {
                    "type": "notification",
                    "event": "payment.succeeded",
                    "object": {"id": payment_id},
                }
            )
        self.assertFalse(
            self.relay.subscription_status("subscriber")["active"]
        )

    async def test_canceled_notification_must_match_verified_status(self):
        await self.relay.create_subscription_checkout(
            "subscriber",
            "device-a",
            "request-c",
        )
        payment_id = next(iter(self.relay.payments))
        with self.assertRaises(server_billing.BillingError):
            await self.relay.process_yookassa_notification(
                {
                    "type": "notification",
                    "event": "payment.canceled",
                    "object": {"id": payment_id},
                }
            )

    async def test_manual_sber_order_requires_admin_approval(self):
        server_billing.YOOKASSA_SHOP_ID = ""
        server_billing.YOOKASSA_SECRET_KEY = ""
        server_billing.YOOKASSA_WEBHOOK_SECRET = ""
        server_billing.SBER_PAYMENT_URL = "https://pay.example/sber"
        server_billing.SUBSCRIPTION_CHECKOUT_URL = (
            "https://mesh.example/meshpro/"
        )

        checkout = await self.relay.create_subscription_checkout(
            "subscriber",
            "device-a",
            "manual-request",
        )
        self.assertEqual("pending", checkout["status"])
        self.assertEqual(
            "https://mesh.example/meshpro/?login=subscriber",
            checkout["confirmation_url"],
        )
        self.assertFalse(
            self.relay.subscription_status("subscriber")["active"]
        )

        direct_order = self.relay.create_manual_subscription_order(
            "subscriber"
        )
        self.assertEqual(checkout["order_id"], direct_order["order_id"])
        self.assertEqual(
            "https://pay.example/sber",
            direct_order["confirmation_url"],
        )
        self.relay.mark_manual_order_submitted(
            direct_order["order_id"],
            direct_order["checkout_key"],
        )
        self.assertEqual(
            "customer_reported",
            self.relay.list_manual_subscription_orders()[0]["status"],
        )
        self.assertFalse(
            self.relay.subscription_status("subscriber")["active"]
        )

        approved = self.relay.approve_manual_subscription_order(
            direct_order["reference"]
        )
        self.assertTrue(approved["subscription"]["active"])
        first_end = approved["subscription"]["current_period_end"]
        duplicate = self.relay.approve_manual_subscription_order(
            direct_order["order_id"]
        )
        self.assertEqual(
            first_end,
            duplicate["subscription"]["current_period_end"],
        )

    async def test_manual_order_reject_does_not_grant_access(self):
        server_billing.YOOKASSA_SHOP_ID = ""
        server_billing.YOOKASSA_SECRET_KEY = ""
        server_billing.YOOKASSA_WEBHOOK_SECRET = ""
        server_billing.SBER_PAYMENT_URL = "https://pay.example/sber"
        server_billing.SUBSCRIPTION_CHECKOUT_URL = (
            "https://mesh.example/meshpro/"
        )
        order = self.relay.create_manual_subscription_order("subscriber")
        rejected = self.relay.reject_manual_subscription_order(
            order["reference"]
        )
        self.assertEqual("rejected", rejected["status"])
        self.assertFalse(
            self.relay.subscription_status("subscriber")["active"]
        )
        with self.assertRaises(server_billing.BillingError):
            self.relay.approve_manual_subscription_order(order["order_id"])

    async def test_lava_checkout_requires_email_then_grants_once(self):
        self.enable_lava()
        email_required = await self.relay.create_subscription_checkout(
            "subscriber",
            "device-a",
            "lava-page",
        )
        self.assertEqual("email_required", email_required["status"])
        self.assertEqual(
            "https://mesh.example/meshpro/?login=subscriber",
            email_required["confirmation_url"],
        )

        checkout = await self.relay.create_subscription_checkout(
            "subscriber",
            "web-checkout",
            "lava-checkout",
            buyer_email="buyer@example.com",
        )
        self.assertEqual("lava", checkout["provider"])
        invoice_id = next(iter(self.relay.lava_invoices))
        self.relay.lava_invoices[invoice_id]["status"] = "COMPLETED"
        notification = {
            "eventType": "payment.success",
            "contractId": invoice_id,
            "product": {"id": "product-meshpro"},
            "buyer": {"email": "buyer@example.com"},
        }
        result = await self.relay.process_lava_notification(notification)
        self.assertTrue(result["subscription"]["active"])
        first_end = result["subscription"]["current_period_end"]
        duplicate = await self.relay.process_lava_notification(notification)
        self.assertEqual(
            first_end,
            duplicate["subscription"]["current_period_end"],
        )

    async def test_lava_recurring_payment_and_cancellation(self):
        self.enable_lava()
        await self.relay.create_subscription_checkout(
            "subscriber",
            "web-checkout",
            "lava-recurring",
            buyer_email="buyer@example.com",
        )
        first_id = next(iter(self.relay.lava_invoices))
        self.relay.lava_invoices[first_id]["status"] = "COMPLETED"
        base_notification = {
            "eventType": "payment.success",
            "contractId": first_id,
            "product": {"id": "product-meshpro"},
            "buyer": {"email": "buyer@example.com"},
        }
        initial = await self.relay.process_lava_notification(base_notification)
        first_end = initial["subscription"]["current_period_end"]

        renewal_id = "lava-renewal-1"
        self.relay.lava_invoices[renewal_id] = {
            "id": renewal_id,
            "type": "SUBSCRIPTION_RENEWAL",
            "status": "COMPLETED",
            "parentInvoiceId": first_id,
            "receipt": {"amount": "199.00", "currency": "RUB"},
            "buyer": {"email": "buyer@example.com"},
            "product": {
                "id": "product-meshpro",
                "offer": {"id": "offer-monthly"},
            },
        }
        renewal_notification = {
            "eventType": "subscription.recurring.payment.success",
            "contractId": renewal_id,
            "parentContractId": first_id,
            "product": {"id": "product-meshpro"},
            "buyer": {"email": "buyer@example.com"},
        }
        renewed = await self.relay.process_lava_notification(
            renewal_notification
        )
        self.assertGreater(
            renewed["subscription"]["current_period_end"],
            first_end,
        )
        renewed_end = renewed["subscription"]["current_period_end"]
        repeated_renewal = await self.relay.process_lava_notification(
            renewal_notification
        )
        self.assertEqual(
            renewed_end,
            repeated_renewal["subscription"]["current_period_end"],
        )

        self.relay.lava_subscriptions[first_id][
            "subscriptionStatus"
        ] = "CANCELLED"
        cancelled = await self.relay.process_lava_notification(
            {
                "eventType": "subscription.cancelled",
                "contractId": first_id,
                "product": {"id": "product-meshpro"},
                "buyer": {"email": "buyer@example.com"},
            }
        )
        self.assertTrue(cancelled["subscription"]["active"])
        self.assertTrue(
            cancelled["subscription"]["cancel_at_period_end"]
        )

    async def test_lava_webhook_product_mismatch_is_rejected(self):
        self.enable_lava()
        await self.relay.create_subscription_checkout(
            "subscriber",
            "web-checkout",
            "lava-fake-product",
            buyer_email="buyer@example.com",
        )
        invoice_id = next(iter(self.relay.lava_invoices))
        self.relay.lava_invoices[invoice_id]["status"] = "COMPLETED"
        with self.assertRaises(server_billing.BillingError):
            await self.relay.process_lava_notification(
                {
                    "eventType": "payment.success",
                    "contractId": invoice_id,
                    "product": {"id": "another-product"},
                    "buyer": {"email": "buyer@example.com"},
                }
            )
        self.assertFalse(
            self.relay.subscription_status("subscriber")["active"]
        )


if __name__ == "__main__":
    unittest.main()
