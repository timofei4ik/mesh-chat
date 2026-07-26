CREATE TABLE IF NOT EXISTS account_chat_state(
    login TEXT NOT NULL,
    chat_key TEXT NOT NULL,
    draft_text TEXT NOT NULL DEFAULT '',
    version BIGINT NOT NULL DEFAULT 1,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY(login, chat_key)
);

CREATE TABLE IF NOT EXISTS message_read_receipts(
    message_id TEXT NOT NULL,
    reader_login TEXT NOT NULL,
    reader_node TEXT NOT NULL DEFAULT '',
    read_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY(message_id, reader_login)
);

CREATE INDEX IF NOT EXISTS idx_message_read_receipts_reader
ON message_read_receipts(reader_login, message_id);
