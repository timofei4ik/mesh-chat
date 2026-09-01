CREATE TABLE IF NOT EXISTS auth_rate_limits(
    bucket TEXT PRIMARY KEY,
    failures INTEGER NOT NULL DEFAULT 0,
    window_started BIGINT NOT NULL,
    blocked_until BIGINT NOT NULL DEFAULT 0,
    updated_at BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_auth_rate_limits_updated
ON auth_rate_limits(updated_at);
