CREATE TABLE service_checks (
    id BIGSERIAL NOT NULL,
    name VARCHAR(100) NOT NULL,
    target VARCHAR(500) NOT NULL,
    type VARCHAR(20) NOT NULL,
    interval_seconds INT NOT NULL,
    timeout_ms INT NOT NULL,
    public_visible BOOLEAN NOT NULL,
    sort_order INT NOT NULL,
    enabled BOOLEAN NOT NULL,
    created_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    updated_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    PRIMARY KEY (id)
);
CREATE INDEX idx_service_checks_enabled_sort ON service_checks (enabled, sort_order);

CREATE TABLE service_check_results (
    id BIGSERIAL NOT NULL,
    service_check_id BIGINT NOT NULL,
    checked_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    success BOOLEAN NOT NULL,
    latency_ms BIGINT NOT NULL,
    status_code INT,
    error VARCHAR(300),
    PRIMARY KEY (id),
    CONSTRAINT fk_service_results_check FOREIGN KEY (service_check_id) REFERENCES service_checks(id) ON DELETE CASCADE
);
CREATE INDEX idx_service_results_check_time ON service_check_results (service_check_id, checked_at);
CREATE INDEX idx_service_results_time ON service_check_results (checked_at);
