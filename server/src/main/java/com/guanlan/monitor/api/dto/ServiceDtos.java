package com.guanlan.monitor.api.dto;

import com.guanlan.monitor.domain.ServiceCheck;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.time.Instant;
import java.util.List;

public final class ServiceDtos {
    private ServiceDtos() {}

    public record Request(
            @NotBlank @Size(max = 100) String name,
            @NotBlank @Size(max = 500) String target,
            @NotNull ServiceCheck.Type type,
            @Min(15) @Max(86400) int intervalSeconds,
            @Min(500) @Max(30000) int timeoutMs,
            boolean publicVisible,
            @Min(-100000) @Max(100000) int sortOrder,
            boolean enabled,
            @Min(1) @Max(20) Integer failureThreshold,
            @Min(0) @Max(30000) Integer latencyThresholdMs,
            @Min(0) @Max(3650) Integer certificateThresholdDays
    ) {}

    public record ResultView(
            Instant checkedAt,
            boolean success,
            long latencyMs,
            Integer statusCode,
            Instant certificateExpiresAt,
            String error
    ) {}

    public record PublicResultView(
            Instant checkedAt,
            boolean success,
            long latencyMs,
            Integer statusCode,
            Instant certificateExpiresAt
    ) {}

    public record View(
            Long id,
            String name,
            String target,
            ServiceCheck.Type type,
            int intervalSeconds,
            int timeoutMs,
            boolean publicVisible,
            int sortOrder,
            boolean enabled,
            int failureThreshold,
            int latencyThresholdMs,
            int certificateThresholdDays,
            boolean alertActive,
            Instant createdAt,
            Instant updatedAt,
            ResultView latest,
            Double availabilityPercent,
            List<ResultView> history
    ) {}

    public record PublicView(
            Long id,
            String name,
            ServiceCheck.Type type,
            int sortOrder,
            PublicResultView latest,
            Double availabilityPercent,
            List<PublicResultView> history
    ) {}
}
