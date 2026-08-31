CREATE TABLE user_device_permissions (
    id BIGSERIAL NOT NULL,
    user_id BIGINT NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    can_view BOOLEAN NOT NULL DEFAULT TRUE,
    can_manage BOOLEAN NOT NULL DEFAULT FALSE,
    can_alert BOOLEAN NOT NULL DEFAULT FALSE,
    can_task BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    updated_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT uq_user_device_permissions UNIQUE (user_id, device_id),
    CONSTRAINT fk_user_device_permissions_user FOREIGN KEY (user_id) REFERENCES app_users(id) ON DELETE CASCADE,
    CONSTRAINT fk_user_device_permissions_device FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE
);

CREATE INDEX idx_user_device_permissions_user ON user_device_permissions (user_id);
CREATE INDEX idx_user_device_permissions_device ON user_device_permissions (device_id);

INSERT INTO user_device_permissions (
    user_id, device_id, can_view, can_manage, can_alert, can_task, created_at, updated_at
)
SELECT
    users.id,
    devices.id,
    TRUE,
    users.role = 'OPERATOR',
    users.role = 'OPERATOR',
    users.role = 'OPERATOR',
    CURRENT_TIMESTAMP,
    CURRENT_TIMESTAMP
FROM app_users users
CROSS JOIN devices
WHERE users.role <> 'ADMIN';
