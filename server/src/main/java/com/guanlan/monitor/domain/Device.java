package com.guanlan.monitor.domain;

import jakarta.persistence.*;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.Instant;
import java.util.UUID;

@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "devices", indexes = {
        @Index(name = "idx_devices_status", columnList = "status"),
        @Index(name = "idx_devices_group_name", columnList = "group_name")
})
public class Device {
    public enum Status { PENDING, ONLINE, OFFLINE }

    @Id
    @Column(length = 36)
    private String id;

    @Column(nullable = false, length = 100)
    private String name;

    @Column(length = 120)
    private String hostname;

    @Column(length = 80)
    private String os;

    @Column(length = 40)
    private String architecture;

    @Column(name = "primary_ip", length = 64)
    private String primaryIp;

    @Column(length = 120)
    private String location;

    @Column(name = "group_name", length = 80)
    private String groupName;

    @Column(name = "agent_key_hash", nullable = false, length = 100)
    private String agentKeyHash;

    @Column(name = "agent_key_prefix", nullable = false, length = 12)
    private String agentKeyPrefix;

    @Column(name = "controller_managed", nullable = false)
    private boolean controllerManaged;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    private Status status = Status.PENDING;

    @Column(name = "last_seen_at")
    private Instant lastSeenAt;

    @Column(name = "hardware_json", columnDefinition = "TEXT")
    private String hardwareJson;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    @PrePersist
    void onCreate() {
        if (id == null) id = UUID.randomUUID().toString();
        createdAt = updatedAt = Instant.now();
    }

    @PreUpdate
    void onUpdate() {
        updatedAt = Instant.now();
    }
}
