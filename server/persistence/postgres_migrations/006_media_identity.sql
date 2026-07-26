ALTER TABLE server_files
ADD COLUMN IF NOT EXISTS media_id TEXT DEFAULT '';

UPDATE server_files
SET media_id=COALESCE(NULLIF(sha256, ''), file_id)
WHERE COALESCE(media_id, '')='';

CREATE INDEX IF NOT EXISTS idx_server_files_media_id
ON server_files(media_id);

ALTER TABLE file_transfer_sessions
ADD COLUMN IF NOT EXISTS media_id TEXT NOT NULL DEFAULT '';

UPDATE file_transfer_sessions
SET media_id=sha256
WHERE COALESCE(media_id, '')='';
