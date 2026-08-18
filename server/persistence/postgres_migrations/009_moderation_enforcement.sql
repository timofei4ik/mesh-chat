CREATE TABLE IF NOT EXISTS moderation_enforcements(
    enforcement_id TEXT PRIMARY KEY,
    report_id TEXT NOT NULL REFERENCES moderation_reports(report_id),
    action TEXT NOT NULL,
    subject_type TEXT NOT NULL,
    subject_id TEXT NOT NULL,
    target_login TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'active',
    expires_at TIMESTAMPTZ,
    reversible INTEGER NOT NULL DEFAULT 1,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    created_by TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    revoked_at TIMESTAMPTZ,
    revoked_by TEXT NOT NULL DEFAULT '',
    revoke_note TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_moderation_enforcements_account
ON moderation_enforcements(target_login, status, action, expires_at);

CREATE INDEX IF NOT EXISTS idx_moderation_enforcements_report
ON moderation_enforcements(report_id, created_at);
