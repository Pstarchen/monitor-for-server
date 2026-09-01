package com.guanlan.monitor.api.dto;

import com.guanlan.monitor.domain.MobileInstallation;
import com.guanlan.monitor.domain.AlertRule;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.time.Instant;
import java.util.List;

public final class MobileInstallationDtos {
    private MobileInstallationDtos() {}

    public record CreateRequest(
            @NotBlank @Size(max = 128) String clientInstallationId,
            @NotNull MobileInstallation.Platform platform,
            @Size(min = 16, max = 4096) String token,
            @Size(max = 40) String appVersion,
            @Size(max = 120) String deviceModel,
            List<String> deviceIds,
            AlertRule.Severity minimumSeverity
    ) {
        public CreateRequest(String clientInstallationId, MobileInstallation.Platform platform,
                             String token, String appVersion, String deviceModel) {
            this(clientInstallationId, platform, token, appVersion, deviceModel, List.of(), AlertRule.Severity.WARNING);
        }
    }

    public record TokenUpdateRequest(
            @NotBlank @Size(min = 16, max = 4096) String token,
            @Size(max = 40) String appVersion
    ) {}

    public record PreferencesRequest(Boolean enabled, List<String> deviceIds,
                                     AlertRule.Severity minimumSeverity) {}

    public record View(
            String id,
            String clientInstallationId,
            MobileInstallation.Platform platform,
            String tokenSuffix,
            String appVersion,
            String deviceModel,
            List<String> deviceIds,
            AlertRule.Severity minimumSeverity,
            boolean enabled,
            Instant lastRegisteredAt,
            Instant createdAt,
            Instant updatedAt
    ) {}

    public record TestResult(String status, Long deliveryId, String message) {}

    public record AdminView(
            String id,
            MobileInstallation.Platform platform,
            String tokenSuffix,
            String appVersion,
            String deviceModel,
            boolean enabled,
            Instant lastRegisteredAt,
            Instant lastTestAt,
            Instant createdAt,
            Instant updatedAt
    ) {}
}
