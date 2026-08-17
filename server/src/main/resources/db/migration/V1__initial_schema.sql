CREATE TABLE app_users (
    id BIGINT NOT NULL AUTO_INCREMENT,
    username VARCHAR(64) NOT NULL,
    password_hash VARCHAR(100) NOT NULL,
    display_name VARCHAR(80) NOT NULL,
    role VARCHAR(20) NOT NULL,
    enabled BOOLEAN NOT NULL,
    created_at TIMESTAMP(6) NOT NULL,
    updated_at TIMESTAMP(6) NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY idx_users_username (username)
) ENGINE=InnoDB;

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
    last_seen_at TIMESTAMP(6),
    hardware_json LONGTEXT,
    created_at TIMESTAMP(6) NOT NULL,
    updated_at TIMESTAMP(6) NOT NULL,
    PRIMARY KEY (id),
    KEY idx_devices_status (status),
    KEY idx_devices_group_name (group_name)
) ENGINE=InnoDB;

CREATE TABLE metric_snapshots (
    id BIGINT NOT NULL AUTO_INCREMENT,
    device_id VARCHAR(36) NOT NULL,
    collected_at TIMESTAMP(6) NOT NULL,
    cpu_usage DOUBLE NOT NULL,
    memory_usage DOUBLE NOT NULL,
    swap_usage DOUBLE NOT NULL,
    load_1 DOUBLE NOT NULL,
    load_5 DOUBLE NOT NULL,
    load_15 DOUBLE NOT NULL,
    disk_usage DOUBLE NOT NULL,
    disk_read_bps DOUBLE NOT NULL,
    disk_write_bps DOUBLE NOT NULL,
    network_sent_bps DOUBLE NOT NULL,
    network_recv_bps DOUBLE NOT NULL,
    tcp_connections INT NOT NULL,
    disks_json LONGTEXT,
    processes_json LONGTEXT,
    services_json LONGTEXT,
    PRIMARY KEY (id),
    CONSTRAINT fk_metrics_device FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE,
    KEY idx_metrics_device_collected (device_id, collected_at),
    KEY idx_metrics_collected (collected_at)
) ENGINE=InnoDB;

CREATE TABLE alert_rules (
    id BIGINT NOT NULL AUTO_INCREMENT,
    name VARCHAR(100) NOT NULL,
    device_id VARCHAR(36),
    metric VARCHAR(30) NOT NULL,
    threshold DOUBLE NOT NULL,
    severity VARCHAR(20) NOT NULL,
    enabled BOOLEAN NOT NULL,
    created_at TIMESTAMP(6) NOT NULL,
    updated_at TIMESTAMP(6) NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT fk_rules_device FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE alert_events (
    id BIGINT NOT NULL AUTO_INCREMENT,
    device_id VARCHAR(36) NOT NULL,
    rule_id BIGINT NOT NULL,
    status VARCHAR(20) NOT NULL,
    observed_value DOUBLE NOT NULL,
    message VARCHAR(300) NOT NULL,
    started_at TIMESTAMP(6) NOT NULL,
    acknowledged_at TIMESTAMP(6),
    acknowledged_by VARCHAR(64),
    resolved_at TIMESTAMP(6),
    PRIMARY KEY (id),
    CONSTRAINT fk_alerts_device FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE,
    CONSTRAINT fk_alerts_rule FOREIGN KEY (rule_id) REFERENCES alert_rules(id) ON DELETE CASCADE,
    KEY idx_alerts_status_started (status, started_at),
    KEY idx_alerts_device_started (device_id, started_at)
) ENGINE=InnoDB;

CREATE TABLE system_settings (
    setting_key VARCHAR(80) NOT NULL,
    setting_value VARCHAR(500) NOT NULL,
    PRIMARY KEY (setting_key)
) ENGINE=InnoDB;

CREATE TABLE audit_logs (
    id BIGINT NOT NULL AUTO_INCREMENT,
    actor VARCHAR(64) NOT NULL,
    action VARCHAR(80) NOT NULL,
    target VARCHAR(80) NOT NULL,
    summary VARCHAR(500),
    created_at TIMESTAMP(6) NOT NULL,
    PRIMARY KEY (id),
    KEY idx_audit_created (created_at)
) ENGINE=InnoDB;
