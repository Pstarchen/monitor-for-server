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
@Table(name = "device_status_events", indexes = {
        @Index(name = "idx_device_status_events_device_changed", columnList = "device_id,changed_at")
})
public class DeviceStatusEvent {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "device_id", nullable = false)
    private Device device;

    @Enumerated(EnumType.STRING)
    @Column(name = "previous_status", length = 20)
    private Device.Status previousStatus;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    private Device.Status status;

    @Column(nullable = false, length = 300)
    private String reason;

    @Column(name = "changed_at", nullable = false, updatable = false)
    private Instant changedAt;

    @PrePersist
    void onCreate() {
        if (changedAt == null) changedAt = Instant.now();
    }
}
