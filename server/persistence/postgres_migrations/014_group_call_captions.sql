CREATE TABLE IF NOT EXISTS call_caption_sessions(
    call_id TEXT PRIMARY KEY,
    sponsor_node TEXT NOT NULL UNIQUE,
    group_id TEXT NOT NULL,
    session_id TEXT NOT NULL,
    expires_at BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS call_caption_members(
    call_id TEXT NOT NULL REFERENCES call_caption_sessions(call_id) ON DELETE CASCADE,
    node_id TEXT NOT NULL,
    consent INTEGER NOT NULL DEFAULT 0,
    revision INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(call_id, node_id)
);

CREATE INDEX IF NOT EXISTS idx_call_caption_expiry ON call_caption_sessions(expires_at);
