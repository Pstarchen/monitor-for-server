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
@Table(name = "ddns_configs")
public class DdnsConfig {
    public enum Provider { DUMMY, WEBHOOK }
    public enum HttpMethod { GET, POST, PUT, PATCH, DELETE }

    @Id @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;
    @Column(nullable = false, length = 100) private String name;
    @Enumerated(EnumType.STRING) @Column(nullable = false, length = 20) private Provider provider;
    @Column(nullable = false, length = 1000) private String domains;
    @Column(name = "webhook_url", length = 1000) private String webhookUrl;
    @Enumerated(EnumType.STRING) @Column(name = "http_method", nullable = false, length = 10) private HttpMethod httpMethod = HttpMethod.GET;
    @Column(name = "headers_json", columnDefinition = "TEXT") private String headersJson;
    @Column(name = "body_template", columnDefinition = "TEXT") private String bodyTemplate;
    @Column(name = "credential_one", length = 1000) private String credentialOne;
    @Column(name = "credential_two", length = 1000) private String credentialTwo;
    @Column(nullable = false) private boolean enabled = true;
    @Column(name = "ipv4_enabled", nullable = false) private boolean ipv4Enabled = true;
    @Column(name = "ipv6_enabled", nullable = false) private boolean ipv6Enabled;
    @Column(name = "max_retries", nullable = false) private int maxRetries = 3;
    @Column(name = "last_status", length = 30) private String lastStatus;
    @Column(name = "last_error", length = 500) private String lastError;
    @Column(name = "last_updated_at") private Instant lastUpdatedAt;
    @Column(name = "created_at", nullable = false, updatable = false) private Instant createdAt;
    @Column(name = "updated_at", nullable = false) private Instant updatedAt;

    @PrePersist void onCreate() { createdAt = updatedAt = Instant.now(); }
    @PreUpdate void onUpdate() { updatedAt = Instant.now(); }
}
