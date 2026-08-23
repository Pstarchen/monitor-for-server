CREATE TABLE ddns_configs (
    id BIGSERIAL NOT NULL,
    name VARCHAR(100) NOT NULL,
    provider VARCHAR(20) NOT NULL,
    domains VARCHAR(1000) NOT NULL,
    webhook_url VARCHAR(1000),
    http_method VARCHAR(10) NOT NULL,
    headers_json TEXT,
    body_template TEXT,
    credential_one VARCHAR(1000),
    credential_two VARCHAR(1000),
    enabled BOOLEAN NOT NULL,
    ipv4_enabled BOOLEAN NOT NULL,
    ipv6_enabled BOOLEAN NOT NULL,
    max_retries INT NOT NULL,
    last_status VARCHAR(30),
    last_error VARCHAR(500),
    last_updated_at TIMESTAMP(6) WITH TIME ZONE,
    created_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    updated_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    PRIMARY KEY (id)
);

ALTER TABLE devices ADD COLUMN ddns_enabled BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE devices ADD COLUMN ddns_config_id BIGINT;
ALTER TABLE devices ADD COLUMN last_ddns_ipv4 VARCHAR(64);
ALTER TABLE devices ADD COLUMN last_ddns_ipv6 VARCHAR(64);
CREATE INDEX idx_devices_ddns_config ON devices (ddns_config_id);
ALTER TABLE devices ADD CONSTRAINT fk_devices_ddns_config FOREIGN KEY (ddns_config_id) REFERENCES ddns_configs(id) ON DELETE SET NULL;
