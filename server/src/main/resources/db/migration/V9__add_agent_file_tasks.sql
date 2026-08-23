ALTER TABLE agent_tasks
    ADD COLUMN operation VARCHAR(20) NOT NULL DEFAULT 'COMMAND',
    ADD COLUMN payload_json TEXT;

CREATE INDEX idx_agent_tasks_operation ON agent_tasks (operation);
