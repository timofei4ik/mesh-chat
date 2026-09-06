CREATE TABLE IF NOT EXISTS call_sfu_sessions(
    call_id TEXT PRIMARY KEY,
    owner_node TEXT NOT NULL,
    group_id TEXT NOT NULL,
    expires_at BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS call_sfu_members(
    call_id TEXT NOT NULL REFERENCES call_sfu_sessions(call_id) ON DELETE CASCADE,
    node_id TEXT NOT NULL,
    PRIMARY KEY(call_id, node_id)
);

CREATE INDEX IF NOT EXISTS idx_call_sfu_expiry ON call_sfu_sessions(expires_at);
