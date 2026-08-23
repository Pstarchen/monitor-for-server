package com.guanlan.monitor.api.dto;

import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.Size;

import java.time.Instant;
import java.util.List;

public final class ApiTokenDtos {
    private ApiTokenDtos() {}

    public record CreateRequest(
            @NotBlank @Size(max = 128) String name,
            @NotEmpty @Size(max = 32) List<@NotBlank @Size(max = 100) String> scopes,
            @Size(max = 1000) List<@NotBlank @Size(max = 64) String> serverIds,
            @Min(0) @Max(3650) Integer expiresInDays
    ) {}

    public record View(
            Long id,
            String name,
            String tokenPrefix,
            List<String> scopes,
            List<String> serverIds,
            Instant expiresAt,
            Instant lastUsedAt,
            String lastUsedIp,
            Instant revokedAt,
            Instant createdAt
    ) {}

    public record Created(View token, String secret) {}
}
