ALTER TABLE devices ADD COLUMN asset_tag VARCHAR(80);
ALTER TABLE devices ADD COLUMN owner_name VARCHAR(100);
ALTER TABLE devices ADD COLUMN vendor VARCHAR(100);
ALTER TABLE devices ADD COLUMN model VARCHAR(120);
ALTER TABLE devices ADD COLUMN serial_number VARCHAR(120);
ALTER TABLE devices ADD COLUMN environment VARCHAR(40);
ALTER TABLE devices ADD COLUMN purchase_date DATE;
ALTER TABLE devices ADD COLUMN warranty_expires_at DATE;
ALTER TABLE devices ADD COLUMN description VARCHAR(500);

CREATE TABLE device_notes (
    id BIGSERIAL NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    author VARCHAR(64) NOT NULL,
    content VARCHAR(2000) NOT NULL,
    created_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT fk_device_notes_device FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE
);
CREATE INDEX idx_device_notes_device_created ON device_notes (device_id, created_at);

CREATE TABLE device_status_events (
    id BIGSERIAL NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    previous_status VARCHAR(20),
    status VARCHAR(20) NOT NULL,
    reason VARCHAR(300) NOT NULL,
    changed_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT fk_device_status_events_device FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE
);
CREATE INDEX idx_device_status_events_device_changed ON device_status_events (device_id, changed_at);
