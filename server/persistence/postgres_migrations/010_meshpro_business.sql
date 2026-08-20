ALTER TABLE account_meshpro_preferences
ADD COLUMN IF NOT EXISTS business_json TEXT NOT NULL DEFAULT '{}';
