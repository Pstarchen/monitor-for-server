ALTER TABLE metric_snapshots
    ADD COLUMN network_interfaces_json TEXT,
    ADD COLUMN ports_json TEXT;
