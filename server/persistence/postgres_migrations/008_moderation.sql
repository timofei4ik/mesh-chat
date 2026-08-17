CREATE TABLE IF NOT EXISTS moderation_reports(
    report_id TEXT PRIMARY KEY,
    reporter_login TEXT NOT NULL,
    reporter_node TEXT NOT NULL DEFAULT '',
    subject_type TEXT NOT NULL,
    subject_id TEXT NOT NULL,
    conversation_id TEXT NOT NULL DEFAULT '',
    target_login TEXT NOT NULL DEFAULT '',
    reason TEXT NOT NULL,
    details TEXT NOT NULL DEFAULT '',
    snapshot_json TEXT NOT NULL DEFAULT '{}',
    status TEXT NOT NULL DEFAULT 'new',
    priority INTEGER NOT NULL DEFAULT 0,
    assigned_to TEXT NOT NULL DEFAULT '',
    ai_category TEXT NOT NULL DEFAULT '',
    ai_confidence DOUBLE PRECISION NOT NULL DEFAULT 0,
    ai_recommendation TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    resolved_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_moderation_reports_queue
ON moderation_reports(status, priority DESC, created_at);

CREATE TABLE IF NOT EXISTS moderation_actions(
    action_id TEXT PRIMARY KEY,
    report_id TEXT NOT NULL REFERENCES moderation_reports(report_id),
    admin_id TEXT NOT NULL,
    action TEXT NOT NULL,
    note TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_moderation_actions_report
ON moderation_actions(report_id, created_at);
