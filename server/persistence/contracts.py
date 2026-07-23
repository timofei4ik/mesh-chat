from typing import Protocol


class IdentityRepository(Protocol):
    def account_exists(self, login: str) -> bool:
        ...

    def credentials(self, login: str):
        ...

    def public_username_owner(
        self,
        public_username: str,
        excluding_login: str = "",
    ):
        ...

    def create_account(self, account: dict) -> None:
        ...

    def record_login(
        self,
        login: str,
        node_id: str,
        encryption_public_key=None,
    ) -> None:
        ...

    def encryption_recovery(self, login: str) -> str:
        ...

    def change_credentials(
        self,
        login: str,
        password_salt: str,
        password_hash: str,
        encryption_recovery: str,
    ) -> None:
        ...

    def verified_email(self, login: str) -> str:
        ...

    def email_owner(self, email: str, excluding_login: str = ""):
        ...

    def is_email_device_trusted(self, login: str, node_id: str) -> bool:
        ...

    def trust_email_device(self, login: str, node_id: str) -> None:
        ...

    def bind_email(self, login: str, email: str, node_id: str) -> None:
        ...

    def latest_email_challenge_age(
        self,
        login: str,
        node_id: str,
        purpose: str,
    ):
        ...

    def create_email_challenge(self, challenge: dict) -> None:
        ...

    def email_challenge(self, challenge_id: str, purpose: str):
        ...

    def discard_email_challenge(self, challenge_id: str) -> None:
        ...

    def increment_email_challenge_attempts(self, challenge_id: str) -> None:
        ...

    def consume_email_challenge(self, challenge_id: str) -> None:
        ...

    def save_account_device(self, device: dict) -> None:
        ...

    def set_account_device_online(
        self,
        login: str,
        node_id: str,
        online: bool,
    ) -> None:
        ...

    def get_account_devices(self, login: str) -> list[dict]:
        ...

    def is_account_device_revoked(self, login: str, node_id: str) -> bool:
        ...

    def reactivate_account_device(self, login: str, node_id: str) -> None:
        ...

    def account_device_exists(self, login: str, node_id: str) -> bool:
        ...

    def revoke_account_device(self, login: str, node_id: str) -> None:
        ...

    def rename_account_device(
        self,
        login: str,
        node_id: str,
        custom_name: str,
    ) -> None:
        ...

    def online_account_nodes(self, login: str) -> list[str]:
        ...

    def login_by_node(self, node_id: str):
        ...

    def update_profile(self, login: str, profile: dict) -> None:
        ...

    def profile_by_public_username(self, public_username: str):
        ...

    def profile_by_node(self, node_id: str):
        ...


class SubscriptionRepository(Protocol):
    def subscription(self, login: str, product: str):
        ...

    def subscriptions(
        self,
        login: str,
        products: tuple[str, ...],
    ) -> list:
        ...

    def provider_event_exists(self, provider_event_id: str) -> bool:
        ...

    def grant(
        self,
        login: str,
        product: str,
        plan_code: str,
        duration_days: int,
        provider: str,
        provider_subscription_id: str,
    ) -> None:
        ...

    def revoke(self, login: str, products: tuple[str, ...]) -> None:
        ...

    def set_provider_lease(
        self,
        login: str,
        product: str,
        provider: str,
        provider_subscription_id: str,
        lease_hours: int,
    ) -> None:
        ...

    def revoke_provider_lease(
        self,
        login: str,
        product: str,
        provider: str,
        provider_subscription_id: str,
    ) -> bool:
        ...

    def mark_cancel_at_period_end(
        self,
        login: str,
        product: str,
        provider: str,
        provider_subscription_id: str,
    ) -> bool:
        ...

    def record_event(
        self,
        login: str,
        product: str,
        event_type: str,
        payload: dict,
        provider_event_id: str = "",
    ) -> None:
        ...

    def rename_product(
        self,
        login: str,
        old_product: str,
        new_product: str,
    ) -> None:
        ...

    def replace_subscription(
        self,
        login: str,
        product: str,
        values,
    ) -> None:
        ...

    def delete_subscription(self, login: str, product: str) -> None:
        ...

    def canonicalize_history(
        self,
        login: str,
        old_product: str,
        new_product: str,
    ) -> None:
        ...

    def create_service_session(
        self,
        token_hash: str,
        login: str,
        service: str,
        device_id: str,
        max_age_days: int,
    ) -> None:
        ...

    def service_session(self, token_hash: str, service: str):
        ...

    def touch_service_session(self, token_hash: str) -> None:
        ...

    def revoke_service_session(
        self,
        token_hash: str,
        service: str,
    ) -> None:
        ...

    def upsert_boosty_recipient(
        self,
        telegram_user_id: int,
        private_chat_id: int,
        telegram_username: str,
    ) -> None:
        ...

    def update_boosty_membership(
        self,
        telegram_user_id: int,
        status: str | None = None,
        error: str = "",
    ) -> None:
        ...

    def create_boosty_code(self, code: dict) -> None:
        ...

    def issue_boosty_subscriber_code(
        self,
        code: dict,
        interval_days: int,
    ) -> None:
        ...

    def boosty_key_wait_seconds(self, telegram_user_id: int) -> int:
        ...

    def active_boosty_code(self, code_hash: str):
        ...

    def consume_boosty_code(self, code_hash: str, login: str) -> bool:
        ...

    def boosty_recipients(self) -> list:
        ...

    def revert_boosty_subscriber_code(
        self,
        code_hash: str,
        telegram_user_id: int,
        error: str,
    ) -> bool:
        ...

    def cleanup_boosty_codes(self) -> None:
        ...


class BillingRepository(Protocol):
    def reusable_order(
        self,
        login: str,
        product: str,
        plan_code: str,
        provider: str,
        statuses: tuple[str, ...],
        max_age_minutes: int,
        buyer_email: str = "",
    ):
        ...

    def order_by_checkout_key(self, checkout_key: str):
        ...

    def create_order(self, order: dict) -> None:
        ...

    def set_checkout_error(self, order_id: str) -> None:
        ...

    def set_provider_checkout(
        self,
        order_id: str,
        payment_id: str,
        status: str,
        confirmation_url: str,
    ) -> None:
        ...

    def checkout_result(self, order_id: str):
        ...

    def manual_status(self, order_id: str, checkout_key: str):
        ...

    def mark_manual_submitted(
        self,
        order_id: str,
        checkout_key: str,
    ) -> None:
        ...

    def list_manual_orders(
        self,
        statuses: tuple[str, ...],
        limit: int,
    ) -> list:
        ...

    def manual_approval_row(self, order_id: str):
        ...

    def manual_result(self, order_id: str):
        ...

    def manual_admin_result(self, order_id: str):
        ...

    def manual_ids_by_prefix(self, prefix: str) -> list[str]:
        ...

    def set_order_status(
        self,
        order_id: str,
        status: str,
        paid: bool = False,
    ) -> None:
        ...

    def lava_notification_order(
        self,
        contract_ids: tuple[str, ...],
        preferred_contract_id: str,
    ):
        ...

    def yookassa_payment_order(
        self,
        payment_id: str,
        order_id: str,
    ):
        ...

    def cancel_yookassa_payment(self, payment_id: str) -> None:
        ...

    def mark_yookassa_succeeded(
        self,
        order_id: str,
        payment_id: str,
        payment_method_id: str,
    ) -> None:
        ...


class UnitOfWork(Protocol):
    identity: IdentityRepository
    subscriptions: SubscriptionRepository
    billing: BillingRepository

    def __enter__(self) -> "UnitOfWork":
        ...

    def __exit__(self, exc_type, exc_value, traceback) -> bool:
        ...

    def commit(self) -> None:
        ...

    def rollback(self) -> None:
        ...


class UnitOfWorkFactory(Protocol):
    def __call__(self, *, write: bool = False) -> UnitOfWork:
        ...
