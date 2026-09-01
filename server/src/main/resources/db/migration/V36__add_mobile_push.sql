ALTER TABLE realtime_outbox ADD COLUMN push_fanout_at TIMESTAMP(6) WITH TIME ZONE;
CREATE INDEX idx_realtime_outbox_push_fanout
    ON realtime_outbox (id)
    WHERE push_fanout_at IS NULL;

CREATE TABLE mobile_installations (
    id VARCHAR(36) NOT NULL,
    user_id BIGINT NOT NULL,
    api_token_id BIGINT NOT NULL,
    client_installation_id VARCHAR(128) NOT NULL,
    platform VARCHAR(20) NOT NULL,
    token_ciphertext TEXT,
    token_fingerprint VARCHAR(64),
    token_suffix VARCHAR(16),
    app_version VARCHAR(40),
    device_model VARCHAR(120),
    device_ids_json TEXT NOT NULL DEFAULT '[]',
    minimum_severity VARCHAR(20) NOT NULL DEFAULT 'WARNING',
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    last_registered_at TIMESTAMP(6) WITH TIME ZONE,
    last_test_at TIMESTAMP(6) WITH TIME ZONE,
    created_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    updated_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT uq_mobile_installation_client UNIQUE (api_token_id, client_installation_id),
    CONSTRAINT fk_mobile_installation_user FOREIGN KEY (user_id) REFERENCES app_users(id) ON DELETE CASCADE,
    CONSTRAINT fk_mobile_installation_api_token FOREIGN KEY (api_token_id) REFERENCES api_tokens(id) ON DELETE CASCADE,
    CONSTRAINT ck_mobile_installation_severity CHECK (minimum_severity IN ('INFO', 'WARNING', 'CRITICAL'))
);

CREATE INDEX idx_mobile_installations_user ON mobile_installations (user_id, updated_at);
CREATE INDEX idx_mobile_installations_enabled ON mobile_installations (enabled, user_id);
CREATE INDEX idx_mobile_installations_token_fingerprint ON mobile_installations (token_fingerprint)
    WHERE token_fingerprint IS NOT NULL;

CREATE TABLE mobile_push_deliveries (
    id BIGSERIAL NOT NULL,
    outbox_event_id VARCHAR(36) NOT NULL,
    installation_id VARCHAR(36) NOT NULL,
    event_type VARCHAR(80) NOT NULL,
    status VARCHAR(20) NOT NULL,
    title VARCHAR(120) NOT NULL,
    body VARCHAR(500) NOT NULL,
    data_json TEXT NOT NULL,
    attempts INT NOT NULL DEFAULT 0,
    next_attempt_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    provider_request_id VARCHAR(128),
    last_error VARCHAR(500),
    created_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    updated_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    sent_at TIMESTAMP(6) WITH TIME ZONE,
    PRIMARY KEY (id),
    CONSTRAINT uq_mobile_push_delivery_event UNIQUE (installation_id, outbox_event_id),
    CONSTRAINT fk_mobile_push_delivery_installation FOREIGN KEY (installation_id) REFERENCES mobile_installations(id) ON DELETE CASCADE
);

CREATE INDEX idx_mobile_push_deliveries_pending
    ON mobile_push_deliveries (next_attempt_at, id)
    WHERE status IN ('PENDING', 'RETRY');
CREATE INDEX idx_mobile_push_deliveries_installation
    ON mobile_push_deliveries (installation_id, created_at);
