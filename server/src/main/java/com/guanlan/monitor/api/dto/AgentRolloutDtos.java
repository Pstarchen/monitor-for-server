package com.guanlan.monitor.api.dto;

import com.guanlan.monitor.domain.AgentRollout;
import com.guanlan.monitor.domain.AgentRolloutMember;
import jakarta.validation.constraints.*;

import java.time.Instant;
import java.util.List;

public final class AgentRolloutDtos {
    private AgentRolloutDtos() {}

    public record CreateRequest(
            @NotBlank @Size(max = 32) String targetVersion,
            @NotEmpty @Size(max = 500) List<@NotBlank @Size(max = 36) String> deviceIds,
            @Positive Long maintenanceWindowId,
            @Min(0) @Max(100) Integer canaryPercent,
            @Min(1) @Max(20) Integer ringCount,
            @Min(1) @Max(100) Integer maxConcurrent,
            @Min(0) @Max(86_400) Integer jitterSeconds,
            @Min(1) @Max(100) Integer failureThreshold,
            @Min(30) @Max(86_400) Integer verificationTimeoutSeconds
    ) {}

    public record ActionRequest(@Size(max = 500) String reason) {}

    public record MemberView(
            Long id,
            String deviceId,
            String deviceName,
            String previousVersion,
            int ring,
            int order,
            Instant eligibleAt,
            Long taskId,
            AgentRolloutMember.Status status,
            int attempt,
            Instant queuedAt,
            String error,
            Instant confirmedAt
    ) {}

    public record View(
            Long id,
            String targetVersion,
            Long maintenanceWindowId,
            int canaryPercent,
            int ringCount,
            int currentRing,
            int maxConcurrent,
            int jitterSeconds,
            int failureThreshold,
            int verificationTimeoutSeconds,
            AgentRollout.Status status,
            String statusReason,
            String createdBy,
            Instant createdAt,
            Instant updatedAt,
            Instant startedAt,
            Instant completedAt,
            Instant rollbackStartedAt,
            Integer rollbackTotal,
            List<MemberView> members
    ) {}
}
