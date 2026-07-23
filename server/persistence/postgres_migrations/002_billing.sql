CREATE TABLE IF NOT EXISTS subscription_orders(
    order_id TEXT PRIMARY KEY,
    checkout_key TEXT NOT NULL UNIQUE,
    login TEXT NOT NULL REFERENCES accounts(login) ON DELETE CASCADE,
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
    paid_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_subscription_order_payment
ON subscription_orders(provider, provider_payment_id)
WHERE provider_payment_id IS NOT NULL AND provider_payment_id != '';

CREATE INDEX IF NOT EXISTS idx_subscription_orders_login
ON subscription_orders(login, product, created_at);
