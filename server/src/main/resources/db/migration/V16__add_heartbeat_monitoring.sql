ALTER TABLE service_checks
    ADD COLUMN heartbeat_token_hash VARCHAR(64),
    ADD COLUMN heartbeat_token_prefix VARCHAR(16);

CREATE INDEX idx_service_checks_heartbeat ON service_checks (type, heartbeat_token_hash);
