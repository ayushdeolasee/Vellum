-- One aggregate counter per UTC day keeps the quota check independent of
-- analytics table size. Seed the current day once for an existing deployment.
CREATE TABLE IF NOT EXISTS analytics_daily_budget (
  day TEXT PRIMARY KEY,
  event_count INTEGER NOT NULL CHECK (event_count >= 0)
) STRICT, WITHOUT ROWID;

INSERT INTO analytics_daily_budget (day, event_count)
SELECT date('now'), COUNT(*) FROM analytics_events
WHERE created_at >= date('now') AND created_at < date('now', '+1 day')
ON CONFLICT(day) DO NOTHING;

-- Runs in the same SQLite statement/transaction as the event insert. A failed
-- insert cannot reserve quota, and a concurrent insert sees the updated count.
CREATE TRIGGER IF NOT EXISTS analytics_events_daily_budget
AFTER INSERT ON analytics_events
BEGIN
  INSERT INTO analytics_daily_budget (day, event_count)
  VALUES (date(NEW.created_at), 1)
  ON CONFLICT(day) DO UPDATE SET event_count = event_count + 1;
END;
