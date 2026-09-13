CREATE TABLE IF NOT EXISTS apple_push_tokens(
    token TEXT NOT NULL,
    kind TEXT NOT NULL DEFAULT 'alert',
    environment TEXT NOT NULL DEFAULT 'production',
    login TEXT REFERENCES accounts(login) ON DELETE CASCADE,
    node_id TEXT NOT NULL,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY(token, kind)
);

CREATE INDEX IF NOT EXISTS idx_apple_push_tokens_node
ON apple_push_tokens(node_id);
