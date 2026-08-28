CREATE TABLE IF NOT EXISTS server_polls(
    poll_id TEXT PRIMARY KEY,
    message_id TEXT NOT NULL UNIQUE,
    group_id TEXT NOT NULL,
    creator_login TEXT NOT NULL,
    question TEXT NOT NULL,
    options_json TEXT NOT NULL,
    is_quiz BOOLEAN NOT NULL DEFAULT FALSE,
    correct_option INTEGER,
    explanation TEXT NOT NULL DEFAULT '',
    allows_multiple BOOLEAN NOT NULL DEFAULT FALSE,
    is_anonymous BOOLEAN NOT NULL DEFAULT TRUE,
    is_closed BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS server_poll_votes(
    poll_id TEXT NOT NULL REFERENCES server_polls(poll_id) ON DELETE CASCADE,
    voter_login TEXT NOT NULL,
    option_index INTEGER NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY(poll_id, voter_login, option_index)
);

CREATE INDEX IF NOT EXISTS idx_server_polls_group
ON server_polls(group_id, created_at);

CREATE INDEX IF NOT EXISTS idx_server_poll_votes_poll
ON server_poll_votes(poll_id, option_index);
