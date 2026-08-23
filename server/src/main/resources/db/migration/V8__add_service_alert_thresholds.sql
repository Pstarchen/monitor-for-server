ALTER TABLE service_checks ADD COLUMN failure_threshold INT NOT NULL DEFAULT 1;
ALTER TABLE service_checks ADD COLUMN latency_threshold_ms INT NOT NULL DEFAULT 0;
ALTER TABLE service_checks ADD COLUMN consecutive_failures INT NOT NULL DEFAULT 0;
ALTER TABLE service_checks ADD COLUMN alert_active BOOLEAN NOT NULL DEFAULT FALSE;
