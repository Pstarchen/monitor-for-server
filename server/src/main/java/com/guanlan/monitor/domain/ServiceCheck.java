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
@Table(name = "service_checks", indexes = {
        @Index(name = "idx_service_checks_enabled_sort", columnList = "enabled,sort_order")
})
public class ServiceCheck {
    public enum Type { HTTP_GET, ICMP_PING, TCPING, HEARTBEAT }

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, length = 100)
    private String name;

    @Column(nullable = false, length = 500)
    private String target;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    private Type type;

    @Column(name = "interval_seconds", nullable = false)
    private int intervalSeconds = 60;

    @Column(name = "timeout_ms", nullable = false)
    private int timeoutMs = 5000;

    @Column(name = "public_visible", nullable = false)
    private boolean publicVisible = true;

    @Column(name = "sort_order", nullable = false)
    private int sortOrder;

    @Column(nullable = false)
    private boolean enabled = true;

    @Column(name = "failure_threshold", nullable = false)
    private int failureThreshold = 1;

    @Column(name = "latency_threshold_ms", nullable = false)
    private int latencyThresholdMs;

    @Column(name = "certificate_threshold_days", nullable = false)
    private int certificateThresholdDays = 14;

    @Column(name = "expected_status")
    private Integer expectedStatus;

    @Column(name = "body_contains", length = 200)
    private String bodyContains;

    @Column(name = "heartbeat_token_hash", length = 64)
    private String heartbeatTokenHash;

    @Column(name = "heartbeat_token_prefix", length = 16)
    private String heartbeatTokenPrefix;

    @Column(name = "consecutive_failures", nullable = false)
    private int consecutiveFailures;

    @Column(name = "alert_active", nullable = false)
    private boolean alertActive;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    @PrePersist
    void onCreate() {
        createdAt = updatedAt = Instant.now();
    }

    @PreUpdate
    void onUpdate() {
        updatedAt = Instant.now();
    }
}
