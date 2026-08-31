CREATE TABLE maintenance_windows (
    id BIGSERIAL NOT NULL,
    name VARCHAR(100) NOT NULL,
    device_id VARCHAR(36),
    rule_id BIGINT,
    starts_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    ends_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    timezone VARCHAR(64) NOT NULL,
    recurrence VARCHAR(20) NOT NULL,
    repeat_until TIMESTAMP(6) WITH TIME ZONE,
    reason VARCHAR(300),
    enabled BOOLEAN NOT NULL,
    created_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    updated_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT fk_maintenance_device FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE,
    CONSTRAINT fk_maintenance_rule FOREIGN KEY (rule_id) REFERENCES alert_rules(id) ON DELETE CASCADE
);
CREATE INDEX idx_maintenance_enabled_time ON maintenance_windows (enabled, starts_at, ends_at);
CREATE INDEX idx_maintenance_device ON maintenance_windows (device_id);
CREATE INDEX idx_maintenance_rule ON maintenance_windows (rule_id);

ALTER TABLE alert_events ADD COLUMN notification_suppressed BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE alert_events ADD COLUMN notified_at TIMESTAMP(6) WITH TIME ZONE;
