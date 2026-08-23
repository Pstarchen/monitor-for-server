ALTER TABLE metric_snapshots ADD COLUMN network_sent_bytes BIGINT NOT NULL DEFAULT 0;
ALTER TABLE metric_snapshots ADD COLUMN network_recv_bytes BIGINT NOT NULL DEFAULT 0;
