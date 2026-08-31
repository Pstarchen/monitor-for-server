package com.guanlan.monitor.api.dto;

import com.guanlan.monitor.domain.MaintenanceWindow;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.time.Instant;

public final class MaintenanceDtos {
    private MaintenanceDtos() {}

    public record WindowRequest(
            @NotBlank @Size(max = 100) String name,
            String deviceId,
            Long ruleId,
            @NotNull Instant startsAt,
            @NotNull Instant endsAt,
            @NotBlank @Size(max = 64) String timezone,
            @NotNull MaintenanceWindow.Recurrence recurrence,
            Instant repeatUntil,
            @Size(max = 300) String reason,
            boolean enabled
    ) {}

    public record WindowView(
            Long id,
            String name,
            String deviceId,
            String deviceName,
            Long ruleId,
            String ruleName,
            String scopeDeviceId,
            Instant startsAt,
            Instant endsAt,
            String timezone,
            MaintenanceWindow.Recurrence recurrence,
            Instant repeatUntil,
            String reason,
            boolean enabled,
            boolean active,
            Instant updatedAt
    ) {}
}
