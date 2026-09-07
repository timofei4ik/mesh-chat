CREATE TABLE IF NOT EXISTS account_bubble_appearance (
    login TEXT PRIMARY KEY,
    style TEXT NOT NULL DEFAULT 'auto'
);
