CREATE TABLE IF NOT EXISTS sqlite_migration_progress(
    source_table TEXT PRIMARY KEY,
    source_rows BIGINT NOT NULL DEFAULT 0,
    copied_rows BIGINT NOT NULL DEFAULT 0,
    source_fingerprint TEXT NOT NULL DEFAULT '',
    target_fingerprint TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'pending',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
