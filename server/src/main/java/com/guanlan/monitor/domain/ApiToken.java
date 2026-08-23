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
@Table(name = "api_tokens", indexes = {
        @Index(name = "idx_api_tokens_user_created", columnList = "user_id,created_at"),
        @Index(name = "idx_api_tokens_hash", columnList = "token_hash", unique = true)
})
public class ApiToken {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "user_id", nullable = false)
    private UserAccount user;

    @Column(nullable = false, length = 128)
    private String name;

    @Column(name = "token_hash", nullable = false, length = 64, unique = true)
    private String tokenHash;

    @Column(name = "token_prefix", nullable = false, length = 20)
    private String tokenPrefix;

    @Column(name = "scopes_json", nullable = false, columnDefinition = "TEXT")
    private String scopesJson;

    @Column(name = "server_ids_json", nullable = false, columnDefinition = "TEXT")
    private String serverIdsJson;

    @Column(name = "expires_at")
    private Instant expiresAt;

    @Column(name = "last_used_at")
    private Instant lastUsedAt;

    @Column(name = "last_used_ip", length = 64)
    private String lastUsedIp;

    @Column(name = "revoked_at")
    private Instant revokedAt;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @PrePersist
    void onCreate() { createdAt = Instant.now(); }
}
