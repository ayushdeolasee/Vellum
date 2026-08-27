CREATE TABLE IF NOT EXISTS testflight_signups (
  id TEXT PRIMARY KEY,
  first_name TEXT NOT NULL,
  last_name TEXT NOT NULL,
  email TEXT NOT NULL COLLATE NOCASE UNIQUE,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  status TEXT NOT NULL DEFAULT 'waiting' CHECK (status IN ('waiting', 'invited'))
) STRICT;

CREATE INDEX IF NOT EXISTS testflight_signups_status_created_at
ON testflight_signups (status, created_at);
