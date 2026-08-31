CREATE TABLE IF NOT EXISTS discovery_scans (
    id BIGSERIAL PRIMARY KEY,
    cidr VARCHAR(43) NOT NULL,
    ports_json TEXT NOT NULL,
    timeout_ms INTEGER NOT NULL,
    concurrency INTEGER NOT NULL,
    status VARCHAR(20) NOT NULL,
    total_hosts INTEGER NOT NULL DEFAULT 0,
    scanned_hosts INTEGER NOT NULL DEFAULT 0,
    discovered_hosts INTEGER NOT NULL DEFAULT 0,
    created_by VARCHAR(64) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL,
    started_at TIMESTAMP WITH TIME ZONE,
    finished_at TIMESTAMP WITH TIME ZONE,
    error VARCHAR(500)
);

CREATE INDEX IF NOT EXISTS idx_discovery_scans_created_at ON discovery_scans (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_discovery_scans_status ON discovery_scans (status);

CREATE TABLE IF NOT EXISTS discovery_results (
    id BIGSERIAL PRIMARY KEY,
    scan_id BIGINT NOT NULL REFERENCES discovery_scans(id) ON DELETE CASCADE,
    address VARCHAR(45) NOT NULL,
    hostname VARCHAR(255),
    reachable BOOLEAN NOT NULL,
    open_ports_json TEXT NOT NULL,
    latency_ms INTEGER,
    discovered_at TIMESTAMP WITH TIME ZONE NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_discovery_results_scan_id ON discovery_results (scan_id, discovered_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS uk_discovery_results_scan_address ON discovery_results (scan_id, address);
