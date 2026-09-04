ALTER TABLE devices ADD COLUMN agent_version VARCHAR(80);
ALTER TABLE devices ADD COLUMN agent_update_status VARCHAR(20) NOT NULL DEFAULT 'IDLE';
ALTER TABLE devices ADD COLUMN agent_last_update_error VARCHAR(500);
ALTER TABLE devices ADD COLUMN agent_update_state_changed_at TIMESTAMP WITH TIME ZONE;

ALTER TABLE devices ADD CONSTRAINT ck_devices_agent_update_status
    CHECK (agent_update_status IN ('IDLE', 'CHECKING', 'DOWNLOADING', 'APPLYING', 'SUCCEEDED', 'FAILED', 'PAUSED', 'ROLLING_BACK'));
