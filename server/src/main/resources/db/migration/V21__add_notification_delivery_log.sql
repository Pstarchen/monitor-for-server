CREATE TABLE notification_deliveries (
    id BIGSERIAL PRIMARY KEY,
    channel VARCHAR(20) NOT NULL,
    status VARCHAR(16) NOT NULL,
    message TEXT NOT NULL,
    error VARCHAR(500),
    attempts INT NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL,
    finished_at TIMESTAMPTZ
);
CREATE INDEX idx_notification_deliveries_created ON notification_deliveries(created_at DESC);
