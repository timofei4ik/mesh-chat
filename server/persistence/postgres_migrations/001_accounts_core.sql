CREATE TABLE IF NOT EXISTS accounts(
    login TEXT PRIMARY KEY,
    password_salt TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    node_id TEXT,
    display_name TEXT,
    public_username TEXT,
    about TEXT,
    avatar_data TEXT,
    encryption_public_key TEXT,
    encryption_recovery TEXT NOT NULL DEFAULT '',
    profile_background TEXT NOT NULL DEFAULT 'mesh',
    profile_effect TEXT NOT NULL DEFAULT 'stars',
    profile_blink_shape TEXT NOT NULL DEFAULT 'auto',
    avatar_decoration TEXT NOT NULL DEFAULT 'none',
    profile_glow INTEGER NOT NULL DEFAULT 0,
    profile_accent BIGINT NOT NULL DEFAULT 4282557941,
    emoji_status TEXT NOT NULL DEFAULT '',
    email TEXT NOT NULL DEFAULT '',
    email_verified_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_login TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_public_username
ON accounts(public_username)
WHERE public_username IS NOT NULL AND public_username != '';

CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_verified_email
ON accounts(LOWER(email))
WHERE email_verified_at IS NOT NULL AND email != '';
