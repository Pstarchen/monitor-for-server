CREATE TABLE realtime_outbox (
    id BIGSERIAL NOT NULL,
    event_id VARCHAR(36) NOT NULL,
    controller_id VARCHAR(36) NOT NULL,
    event_type VARCHAR(80) NOT NULL,
    aggregate_type VARCHAR(40) NOT NULL,
    aggregate_id VARCHAR(128) NOT NULL,
    device_id VARCHAR(36),
    payload_json TEXT NOT NULL,
    occurred_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    available_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    published_at TIMESTAMP(6) WITH TIME ZONE,
    publish_attempts INT NOT NULL DEFAULT 0,
    last_error VARCHAR(500),
    PRIMARY KEY (id),
    CONSTRAINT uq_realtime_outbox_event_id UNIQUE (event_id)
);

CREATE INDEX idx_realtime_outbox_pending
    ON realtime_outbox (available_at, id)
    WHERE published_at IS NULL;
CREATE INDEX idx_realtime_outbox_replay
    ON realtime_outbox (id, occurred_at);
CREATE INDEX idx_realtime_outbox_device
    ON realtime_outbox (device_id, id);
