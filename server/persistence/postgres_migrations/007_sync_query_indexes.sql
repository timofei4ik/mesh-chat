-- Hot paths used while producing a full account snapshot and applying
-- multi-device state.  These are intentionally narrow indexes: message IDs
-- and group membership are looked up much more often than the full rows.

CREATE INDEX IF NOT EXISTS idx_group_members_login_group
ON server_group_members(login, group_id);

CREATE INDEX IF NOT EXISTS idx_group_members_node_group
ON server_group_members(node_id, group_id);

CREATE INDEX IF NOT EXISTS idx_group_messages_group_created
ON server_group_messages(group_id, created_at);

CREATE INDEX IF NOT EXISTS idx_server_files_group_created
ON server_files(group_id, created_at);

CREATE INDEX IF NOT EXISTS idx_server_reactions_message
ON server_reactions(message_id, created_at);

CREATE INDEX IF NOT EXISTS idx_server_pins_message_created
ON server_pins(message_id, created_at);

CREATE INDEX IF NOT EXISTS idx_read_receipts_message_read
ON message_read_receipts(message_id, read_at);
