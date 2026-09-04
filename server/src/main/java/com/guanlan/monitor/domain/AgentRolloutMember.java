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
@Table(name = "agent_rollout_members", uniqueConstraints = {
        @UniqueConstraint(name = "uq_agent_rollout_member_device", columnNames = {"rollout_id", "device_id"})
}, indexes = {
        @Index(name = "idx_agent_rollout_members_rollout_ring", columnList = "rollout_id,ring_number,status,order_index"),
        @Index(name = "idx_agent_rollout_members_task", columnList = "task_id")
})
public class AgentRolloutMember {
    public enum Status {
        PENDING, QUEUED, ACCEPTED, CONFIRMED, FAILED, CANCELED,
        ROLLBACK_PENDING, ROLLBACK_QUEUED, ROLLBACK_ACCEPTED, ROLLBACK_CONFIRMED, ROLLBACK_FAILED
    }

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "rollout_id", nullable = false)
    private AgentRollout rollout;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "device_id", nullable = false)
    private Device device;

    @Column(name = "previous_version", nullable = false, length = 32)
    private String previousVersion;

    @Column(name = "ring_number", nullable = false)
    private int ringNumber;

    @Column(name = "order_index", nullable = false)
    private int orderIndex;

    @Column(name = "eligible_at")
    private Instant eligibleAt;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "task_id")
    private AgentTask task;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 24)
    private Status status = Status.PENDING;

    @Column(nullable = false)
    private int attempt;

    @Column(name = "queued_at")
    private Instant queuedAt;

    @Column(length = 500)
    private String error;

    @Column(name = "confirmed_at")
    private Instant confirmedAt;

    @Column(name = "rollback_participant", nullable = false)
    private boolean rollbackParticipant;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

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
