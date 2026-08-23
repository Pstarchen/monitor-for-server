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
@Table(name = "service_check_results", indexes = {
        @Index(name = "idx_service_results_check_time", columnList = "service_check_id,checked_at"),
        @Index(name = "idx_service_results_time", columnList = "checked_at")
})
public class ServiceCheckResult {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "service_check_id", nullable = false)
    private ServiceCheck serviceCheck;

    @Column(name = "checked_at", nullable = false)
    private Instant checkedAt;

    @Column(nullable = false)
    private boolean success;

    @Column(name = "latency_ms", nullable = false)
    private long latencyMs;

    @Column(name = "status_code")
    private Integer statusCode;

    @Column(name = "certificate_expires_at")
    private Instant certificateExpiresAt;

    @Column(length = 300)
    private String error;
}
