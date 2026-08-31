package com.guanlan.monitor.api.dto;

import com.guanlan.monitor.domain.AlertEvent;
import com.guanlan.monitor.domain.AlertRule;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.PositiveOrZero;
import jakarta.validation.constraints.Size;

import java.time.Instant;
import java.util.List;

public final class AlertDtos {
    private AlertDtos() {}

    public record RuleRequest(
            @NotBlank @Size(max = 100) String name,
            String deviceId,
            @NotNull AlertRule.Metric metric,
            @PositiveOrZero double threshold,
            @NotNull AlertRule.Severity severity,
            boolean enabled,
            @Size(max = 255) String targetName
    ) {}

    public record RuleView(
            Long id, String name, String deviceId, String deviceName,
            AlertRule.Metric metric, double threshold, AlertRule.Severity severity, String targetName,
            boolean enabled, Instant updatedAt
    ) {}

    public record EventView(
            Long id, String deviceId, String deviceName, Long ruleId, String ruleName,
            AlertRule.Severity severity, AlertEvent.Status status, double value,
            String message, Instant startedAt, Instant acknowledgedAt,
            String acknowledgedBy, Instant resolvedAt, boolean notificationSuppressed, Instant notifiedAt
    ) {}

    public record AcknowledgeRequest(
            @NotEmpty @Size(max = 100) List<Long> ids
    ) {}
}

