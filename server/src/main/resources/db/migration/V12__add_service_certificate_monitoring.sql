ALTER TABLE service_checks
    ADD COLUMN certificate_threshold_days INT NOT NULL DEFAULT 14;

ALTER TABLE service_check_results
    ADD COLUMN certificate_expires_at TIMESTAMP(6) WITH TIME ZONE;
