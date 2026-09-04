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
@Table(name = "agent_rollouts", indexes = {
        @Index(name = "idx_agent_rollouts_status_updated", columnList = "status,updated_at")
})
public class AgentRollout {
    public enum Status { DRAFT, RUNNING, PAUSED, CANCELED, SUCCEEDED, FAILED, ROLLING_BACK, ROLLED_BACK }

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "target_version", nullable = false, length = 32)
    private String targetVersion;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "maintenance_window_id")
    private MaintenanceWindow maintenanceWindow;

    @Column(name = "canary_percent", nullable = false)
    private int canaryPercent;

    @Column(name = "ring_count", nullable = false)
    private int ringCount;

    @Column(name = "current_ring", nullable = false)
    private int currentRing = -1;

    @Column(name = "max_concurrent", nullable = false)
    private int maxConcurrent;

    @Column(name = "jitter_seconds", nullable = false)
    private int jitterSeconds;

    @Column(name = "failure_threshold", nullable = false)
    private int failureThreshold;

    @Column(name = "verification_timeout_seconds", nullable = false)
    private int verificationTimeoutSeconds;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 24)
    private Status status = Status.DRAFT;

    @Column(name = "status_reason", length = 500)
    private String statusReason;

    @Column(name = "created_by", nullable = false, length = 64)
    private String createdBy;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    @Column(name = "started_at")
    private Instant startedAt;

    @Column(name = "completed_at")
    private Instant completedAt;

    @Column(name = "rollback_started_at")
    private Instant rollbackStartedAt;

    @PrePersist
    void onCreate() {
        if (createdAt == null) createdAt = Instant.now();
        updatedAt = createdAt;
    }

    @PreUpdate
    void onUpdate() {
        updatedAt = Instant.now();
    }
}
