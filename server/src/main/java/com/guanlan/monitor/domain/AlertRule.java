package com.guanlan.monitor.domain;

import jakarta.persistence.*;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.Instant;

@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "alert_rules")
public class AlertRule {
    public enum Metric { CPU_USAGE, MEMORY_USAGE, DISK_USAGE, LOAD_1, DISK_READ_BPS, DISK_WRITE_BPS,
        CONTAINER_CPU_USAGE, CONTAINER_MEMORY_USAGE, GPU_USAGE, BATTERY_PERCENT, SMART_FAILURES,
        TCP_CONNECTIONS, NETWORK_RECV_BPS, NETWORK_SENT_BPS, TEMPERATURE, DEVICE_OFFLINE }
    public enum Severity { INFO, WARNING, CRITICAL }

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, length = 100)
    private String name;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "device_id")
    private Device device;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 30)
    private Metric metric;

    @Column(nullable = false)
    private double threshold;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    private Severity severity = Severity.WARNING;

    @Column(nullable = false)
    private boolean enabled = true;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    @PrePersist
    void onCreate() { createdAt = updatedAt = Instant.now(); }

    @PreUpdate
    void onUpdate() { updatedAt = Instant.now(); }
}
