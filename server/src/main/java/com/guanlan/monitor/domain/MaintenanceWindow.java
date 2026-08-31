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
@Table(name = "maintenance_windows", indexes = {
        @Index(name = "idx_maintenance_enabled_time", columnList = "enabled,starts_at,ends_at"),
        @Index(name = "idx_maintenance_device", columnList = "device_id"),
        @Index(name = "idx_maintenance_rule", columnList = "rule_id")
})
public class MaintenanceWindow {
    public enum Recurrence { NONE, DAILY, WEEKLY }

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, length = 100)
    private String name;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "device_id")
    private Device device;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "rule_id")
    private AlertRule rule;

    @Column(name = "starts_at", nullable = false)
    private Instant startsAt;

    @Column(name = "ends_at", nullable = false)
    private Instant endsAt;

    @Column(nullable = false, length = 64)
    private String timezone = "UTC";

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    private Recurrence recurrence = Recurrence.NONE;

    @Column(name = "repeat_until")
    private Instant repeatUntil;

    @Column(length = 300)
    private String reason;

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
