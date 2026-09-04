CREATE TABLE agent_rollouts (
    id BIGSERIAL NOT NULL,
    target_version VARCHAR(32) NOT NULL,
    maintenance_window_id BIGINT,
    canary_percent INT NOT NULL,
    ring_count INT NOT NULL,
    current_ring INT NOT NULL DEFAULT -1,
    max_concurrent INT NOT NULL,
    jitter_seconds INT NOT NULL,
    failure_threshold INT NOT NULL,
    verification_timeout_seconds INT NOT NULL,
    status VARCHAR(24) NOT NULL,
    status_reason VARCHAR(500),
    created_by VARCHAR(64) NOT NULL,
    created_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    updated_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    started_at TIMESTAMP(6) WITH TIME ZONE,
    completed_at TIMESTAMP(6) WITH TIME ZONE,
    rollback_started_at TIMESTAMP(6) WITH TIME ZONE,
    PRIMARY KEY (id),
    CONSTRAINT fk_agent_rollouts_maintenance_window FOREIGN KEY (maintenance_window_id)
        REFERENCES maintenance_windows(id) ON DELETE SET NULL,
    CONSTRAINT ck_agent_rollouts_canary_percent CHECK (canary_percent BETWEEN 0 AND 100),
    CONSTRAINT ck_agent_rollouts_ring_count CHECK (ring_count BETWEEN 1 AND 20),
    CONSTRAINT ck_agent_rollouts_max_concurrent CHECK (max_concurrent BETWEEN 1 AND 100),
    CONSTRAINT ck_agent_rollouts_jitter_seconds CHECK (jitter_seconds BETWEEN 0 AND 86400),
    CONSTRAINT ck_agent_rollouts_failure_threshold CHECK (failure_threshold BETWEEN 1 AND 100),
    CONSTRAINT ck_agent_rollouts_verification_timeout CHECK (verification_timeout_seconds BETWEEN 30 AND 86400),
    CONSTRAINT ck_agent_rollouts_status CHECK (status IN (
        'DRAFT', 'RUNNING', 'PAUSED', 'CANCELED', 'SUCCEEDED', 'FAILED', 'ROLLING_BACK', 'ROLLED_BACK'
    ))
);

CREATE INDEX idx_agent_rollouts_status_updated ON agent_rollouts (status, updated_at);

CREATE TABLE agent_rollout_members (
    id BIGSERIAL NOT NULL,
    rollout_id BIGINT NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    previous_version VARCHAR(32) NOT NULL,
    ring_number INT NOT NULL,
    order_index INT NOT NULL,
    eligible_at TIMESTAMP(6) WITH TIME ZONE,
    task_id BIGINT,
    status VARCHAR(24) NOT NULL,
    attempt INT NOT NULL DEFAULT 0,
    queued_at TIMESTAMP(6) WITH TIME ZONE,
    error VARCHAR(500),
    confirmed_at TIMESTAMP(6) WITH TIME ZONE,
    rollback_participant BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    updated_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT uq_agent_rollout_member_device UNIQUE (rollout_id, device_id),
    CONSTRAINT fk_agent_rollout_members_rollout FOREIGN KEY (rollout_id)
        REFERENCES agent_rollouts(id) ON DELETE CASCADE,
    CONSTRAINT fk_agent_rollout_members_device FOREIGN KEY (device_id)
        REFERENCES devices(id) ON DELETE CASCADE,
    CONSTRAINT fk_agent_rollout_members_task FOREIGN KEY (task_id)
        REFERENCES agent_tasks(id) ON DELETE SET NULL,
    CONSTRAINT ck_agent_rollout_members_status CHECK (status IN (
        'PENDING', 'QUEUED', 'ACCEPTED', 'CONFIRMED', 'FAILED', 'CANCELED',
        'ROLLBACK_PENDING', 'ROLLBACK_QUEUED', 'ROLLBACK_ACCEPTED', 'ROLLBACK_CONFIRMED', 'ROLLBACK_FAILED'
    ))
);

CREATE INDEX idx_agent_rollout_members_rollout_ring
    ON agent_rollout_members (rollout_id, ring_number, status, order_index);
CREATE INDEX idx_agent_rollout_members_task ON agent_rollout_members (task_id);
