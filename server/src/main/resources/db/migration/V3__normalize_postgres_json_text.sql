-- Hibernate's @Lob mapping previously stored these TEXT fields as PostgreSQL
-- large-object OIDs. Convert existing numeric references back to UTF-8 JSON.
UPDATE devices
SET hardware_json = convert_from(lo_get(hardware_json::oid), 'UTF8')
WHERE hardware_json ~ '^[0-9]+$';

UPDATE metric_snapshots
SET disks_json = convert_from(lo_get(disks_json::oid), 'UTF8')
WHERE disks_json ~ '^[0-9]+$';

UPDATE metric_snapshots
SET processes_json = convert_from(lo_get(processes_json::oid), 'UTF8')
WHERE processes_json ~ '^[0-9]+$';

UPDATE metric_snapshots
SET services_json = convert_from(lo_get(services_json::oid), 'UTF8')
WHERE services_json ~ '^[0-9]+$';
