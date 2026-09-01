package com.guanlan.monitor.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.FetchType;
import jakarta.persistence.Id;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.PrePersist;
import jakarta.persistence.PreUpdate;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.Instant;
import java.util.UUID;

@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "mobile_installations")
public class MobileInstallation {
    public enum Platform { HARMONYOS }

    @Id
    @Column(length = 36)
    private String id;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "user_id", nullable = false)
    private UserAccount user;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "api_token_id", nullable = false, updatable = false)
    private ApiToken apiToken;

    @Column(name = "client_installation_id", nullable = false, length = 128)
    private String clientInstallationId;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    private Platform platform;

    @Column(name = "token_ciphertext", columnDefinition = "TEXT")
    private String tokenCiphertext;

    @Column(name = "token_fingerprint", length = 64)
    private String tokenFingerprint;

    @Column(name = "token_suffix", length = 16)
    private String tokenSuffix;

    @Column(name = "app_version", length = 40)
    private String appVersion;

    @Column(name = "device_model", length = 120)
    private String deviceModel;

    @Column(name = "device_ids_json", nullable = false, columnDefinition = "TEXT")
    private String deviceIdsJson = "[]";

    @Enumerated(EnumType.STRING)
    @Column(name = "minimum_severity", nullable = false, length = 20)
    private AlertRule.Severity minimumSeverity = AlertRule.Severity.WARNING;

    @Column(nullable = false)
    private boolean enabled = true;

    @Column(name = "last_registered_at")
    private Instant lastRegisteredAt;

    @Column(name = "last_test_at")
    private Instant lastTestAt;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    @PrePersist
    void onCreate() {
        Instant now = Instant.now();
        if (id == null) id = UUID.randomUUID().toString();
        createdAt = updatedAt = now;
    }

    @PreUpdate
    void onUpdate() {
        updatedAt = Instant.now();
    }
}
