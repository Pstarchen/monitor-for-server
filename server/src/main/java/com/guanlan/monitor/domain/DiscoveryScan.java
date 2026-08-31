package com.guanlan.monitor.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Index;
import jakarta.persistence.PrePersist;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.Instant;

@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "discovery_scans", indexes = {
        @Index(name = "idx_discovery_scans_created_at", columnList = "created_at"),
        @Index(name = "idx_discovery_scans_status", columnList = "status")
})
public class DiscoveryScan {
    public enum Status { QUEUED, RUNNING, SUCCEEDED, FAILED, CANCELED }

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, length = 43)
    private String cidr;

    @Column(name = "ports_json", nullable = false, columnDefinition = "TEXT")
    private String portsJson;

    @Column(name = "timeout_ms", nullable = false)
    private int timeoutMs;

    @Column(nullable = false)
    private int concurrency;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    private Status status = Status.QUEUED;

    @Column(name = "total_hosts", nullable = false)
    private int totalHosts;

    @Column(name = "scanned_hosts", nullable = false)
    private int scannedHosts;

    @Column(name = "discovered_hosts", nullable = false)
    private int discoveredHosts;

    @Column(name = "created_by", nullable = false, length = 64)
    private String createdBy;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "started_at")
    private Instant startedAt;

    @Column(name = "finished_at")
    private Instant finishedAt;

    @Column(length = 500)
    private String error;

    @PrePersist
    void onCreate() { createdAt = Instant.now(); }
}
