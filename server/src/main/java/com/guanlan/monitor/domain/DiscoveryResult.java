package com.guanlan.monitor.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Index;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.Instant;

@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "discovery_results", indexes = {
        @Index(name = "idx_discovery_results_scan_id", columnList = "scan_id,discovered_at")
})
public class DiscoveryResult {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "scan_id", nullable = false)
    private DiscoveryScan scan;

    @Column(nullable = false, length = 45)
    private String address;

    @Column(length = 255)
    private String hostname;

    @Column(nullable = false)
    private boolean reachable;

    @Column(name = "open_ports_json", nullable = false, columnDefinition = "TEXT")
    private String openPortsJson;

    @Column(name = "latency_ms")
    private Integer latencyMs;

    @Column(name = "discovered_at", nullable = false)
    private Instant discoveredAt;

    public DiscoveryResult(DiscoveryScan scan, String address, String hostname, boolean reachable,
                           String openPortsJson, Integer latencyMs) {
        this.scan = scan;
        this.address = address;
        this.hostname = hostname;
        this.reachable = reachable;
        this.openPortsJson = openPortsJson;
        this.latencyMs = latencyMs;
        this.discoveredAt = Instant.now();
    }
}
