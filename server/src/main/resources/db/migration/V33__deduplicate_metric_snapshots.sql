DELETE FROM metric_snapshots duplicate
USING metric_snapshots canonical
WHERE duplicate.device_id = canonical.device_id
  AND duplicate.collected_at = canonical.collected_at
  AND duplicate.id > canonical.id;

ALTER TABLE metric_snapshots
    ADD CONSTRAINT uq_metrics_device_collected UNIQUE (device_id, collected_at);
