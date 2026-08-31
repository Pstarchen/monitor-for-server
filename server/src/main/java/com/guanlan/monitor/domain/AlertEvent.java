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
@Table(name = "alert_events", indexes = {
        @Index(name = "idx_alerts_status_started", columnList = "status,started_at"),
        @Index(name = "idx_alerts_device_started", columnList = "device_id,started_at")
})
public class AlertEvent {
    public enum Status { OPEN, ACKNOWLEDGED, RESOLVED }

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "device_id", nullable = false)
    private Device device;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "rule_id", nullable = false)
    private AlertRule rule;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    private Status status = Status.OPEN;

    @Column(name = "observed_value", nullable = false)
    private double value;

    @Column(nullable = false, length = 300)
    private String message;

    @Column(name = "started_at", nullable = false)
    private Instant startedAt;

    @Column(name = "acknowledged_at")
    private Instant acknowledgedAt;

    @Column(name = "acknowledged_by", length = 64)
    private String acknowledgedBy;

    @Column(name = "resolved_at")
    private Instant resolvedAt;

    @Column(name = "notification_suppressed", nullable = false)
    private boolean notificationSuppressed;

    @Column(name = "notified_at")
    private Instant notifiedAt;
}
