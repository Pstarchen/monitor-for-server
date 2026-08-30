ALTER TABLE devices ADD COLUMN tags_json TEXT;
ALTER TABLE alert_rules ADD COLUMN target_name VARCHAR(255);
