CREATE TABLE agent_tasks (
    id BIGSERIAL NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    command VARCHAR(128) NOT NULL,
    args_json TEXT NOT NULL,
    timeout_seconds INT NOT NULL,
    max_output_bytes INT NOT NULL,
    status VARCHAR(20) NOT NULL,
    created_by VARCHAR(64) NOT NULL,
    created_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    started_at TIMESTAMP(6) WITH TIME ZONE,
    finished_at TIMESTAMP(6) WITH TIME ZONE,
    exit_code INT,
    stdout TEXT,
    stderr TEXT,
    error VARCHAR(500),
    PRIMARY KEY (id),
    CONSTRAINT fk_agent_tasks_device FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE
);
CREATE INDEX idx_agent_tasks_device_status_created ON agent_tasks (device_id, status, created_at);
CREATE INDEX idx_agent_tasks_status_created ON agent_tasks (status, created_at);
