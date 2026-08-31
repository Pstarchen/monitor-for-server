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
@Table(name = "user_device_permissions", uniqueConstraints =
        @UniqueConstraint(name = "uq_user_device_permissions", columnNames = {"user_id", "device_id"}), indexes = {
        @Index(name = "idx_user_device_permissions_user", columnList = "user_id"),
        @Index(name = "idx_user_device_permissions_device", columnList = "device_id")
})
public class UserDevicePermission {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "user_id", nullable = false)
    private UserAccount user;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "device_id", nullable = false)
    private Device device;

    @Column(name = "can_view", nullable = false)
    private boolean canView;

    @Column(name = "can_manage", nullable = false)
    private boolean canManage;

    @Column(name = "can_alert", nullable = false)
    private boolean canAlert;

    @Column(name = "can_task", nullable = false)
    private boolean canTask;

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
