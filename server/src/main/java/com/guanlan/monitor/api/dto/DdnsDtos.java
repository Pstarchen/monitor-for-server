package com.guanlan.monitor.api.dto;

import com.guanlan.monitor.domain.DdnsConfig;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.time.Instant;
import java.util.List;

public final class DdnsDtos {
    private DdnsDtos() {}

    public record Request(
            @NotBlank @Size(max = 100) String name,
            @NotNull DdnsConfig.Provider provider,
            @NotNull @Size(min = 1, max = 20) List<@NotBlank @Size(max = 253) String> domains,
            @Size(max = 1000) String webhookUrl,
            DdnsConfig.HttpMethod method,
            @Size(max = 10000) String headersJson,
            @Size(max = 10000) String bodyTemplate,
            @Size(max = 500) String credentialOne,
            @Size(max = 500) String credentialTwo,
            boolean enabled,
            boolean ipv4Enabled,
            boolean ipv6Enabled,
            @Min(1) @Max(10) Integer maxRetries
    ) {}

    public record View(
            Long id, String name, DdnsConfig.Provider provider, List<String> domains,
            boolean webhookConfigured, DdnsConfig.HttpMethod method, boolean enabled,
            boolean ipv4Enabled, boolean ipv6Enabled, int maxRetries,
            String lastStatus, String lastError, Instant lastUpdatedAt,
            boolean credentialOneConfigured, boolean credentialTwoConfigured
    ) {}
}
