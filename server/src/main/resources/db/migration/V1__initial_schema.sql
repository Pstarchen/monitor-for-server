CREATE TABLE app_users (
    id BIGSERIAL NOT NULL,
    username VARCHAR(64) NOT NULL,
    password_hash VARCHAR(100) NOT NULL,
    display_name VARCHAR(80) NOT NULL,
    role VARCHAR(20) NOT NULL,
    enabled BOOLEAN NOT NULL,
    created_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    updated_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT uq_users_username UNIQUE (username)
);

CREATE TABLE devices (
    id VARCHAR(36) NOT NULL,
    name VARCHAR(100) NOT NULL,
    hostname VARCHAR(120),
    os VARCHAR(80),
    architecture VARCHAR(40),
    primary_ip VARCHAR(64),
    location VARCHAR(120),
    group_name VARCHAR(80),
    agent_key_hash VARCHAR(100) NOT NULL,
    agent_key_prefix VARCHAR(12) NOT NULL,
    status VARCHAR(20) NOT NULL,
    last_seen_at TIMESTAMP(6) WITH TIME ZONE,
    hardware_json TEXT,
    created_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    updated_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    PRIMARY KEY (id)
);
CREATE INDEX idx_devices_status ON devices (status);
CREATE INDEX idx_devices_group_name ON devices (group_name);

CREATE TABLE metric_snapshots (
    id BIGSERIAL NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    collected_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    cpu_usage DOUBLE PRECISION NOT NULL,
    memory_usage DOUBLE PRECISION NOT NULL,
    swap_usage DOUBLE PRECISION NOT NULL,
    load_1 DOUBLE PRECISION NOT NULL,
    load_5 DOUBLE PRECISION NOT NULL,
    load_15 DOUBLE PRECISION NOT NULL,
    disk_usage DOUBLE PRECISION NOT NULL,
    disk_read_bps DOUBLE PRECISION NOT NULL,
    disk_write_bps DOUBLE PRECISION NOT NULL,
    network_sent_bps DOUBLE PRECISION NOT NULL,
    network_recv_bps DOUBLE PRECISION NOT NULL,
    tcp_connections INT NOT NULL,
    disks_json TEXT,
    processes_json TEXT,
    services_json TEXT,
    PRIMARY KEY (id),
    CONSTRAINT fk_metrics_device FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE
);
CREATE INDEX idx_metrics_device_collected ON metric_snapshots (device_id, collected_at);
CREATE INDEX idx_metrics_collected ON metric_snapshots (collected_at);

CREATE TABLE alert_rules (
    id BIGSERIAL NOT NULL,
    name VARCHAR(100) NOT NULL,
    device_id VARCHAR(36),
    metric VARCHAR(30) NOT NULL,
    threshold DOUBLE PRECISION NOT NULL,
    severity VARCHAR(20) NOT NULL,
    enabled BOOLEAN NOT NULL,
    created_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    updated_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT fk_rules_device FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE
);

CREATE TABLE alert_events (
    id BIGSERIAL NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    rule_id BIGINT NOT NULL,
    status VARCHAR(20) NOT NULL,
    observed_value DOUBLE PRECISION NOT NULL,
    message VARCHAR(300) NOT NULL,
    started_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    acknowledged_at TIMESTAMP(6) WITH TIME ZONE,
    acknowledged_by VARCHAR(64),
    resolved_at TIMESTAMP(6) WITH TIME ZONE,
    PRIMARY KEY (id),
    CONSTRAINT fk_alerts_device FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE,
    CONSTRAINT fk_alerts_rule FOREIGN KEY (rule_id) REFERENCES alert_rules(id) ON DELETE CASCADE
);
CREATE INDEX idx_alerts_status_started ON alert_events (status, started_at);
CREATE INDEX idx_alerts_device_started ON alert_events (device_id, started_at);

CREATE TABLE system_settings (
    setting_key VARCHAR(80) NOT NULL,
    setting_value VARCHAR(500) NOT NULL,
    PRIMARY KEY (setting_key)
);

CREATE TABLE audit_logs (
    id BIGSERIAL NOT NULL,
    actor VARCHAR(64) NOT NULL,
    action VARCHAR(80) NOT NULL,
    target VARCHAR(80) NOT NULL,
    summary VARCHAR(500),
    created_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    PRIMARY KEY (id)
);
CREATE INDEX idx_audit_created ON audit_logs (created_at);
