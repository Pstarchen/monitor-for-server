ALTER TABLE metric_snapshots
    ADD COLUMN IF NOT EXISTS integrity_changes INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS firewall_inactive INTEGER,
    ADD COLUMN IF NOT EXISTS firewall_json TEXT,
    ADD COLUMN IF NOT EXISTS cron_jobs_json TEXT,
    ADD COLUMN IF NOT EXISTS logs_json TEXT,
    ADD COLUMN IF NOT EXISTS integrity_json TEXT;
