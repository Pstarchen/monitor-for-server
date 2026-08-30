ALTER TABLE service_checks ADD COLUMN expected_status INT;
ALTER TABLE service_checks ADD COLUMN body_contains VARCHAR(200);
