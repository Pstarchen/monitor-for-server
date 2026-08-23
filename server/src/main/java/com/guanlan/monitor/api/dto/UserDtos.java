package com.guanlan.monitor.api.dto;

import com.guanlan.monitor.domain.UserAccount;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import java.time.Instant;

public final class UserDtos {
    private UserDtos() {}

    public record CreateRequest(
            @NotBlank @Pattern(regexp = "[A-Za-z0-9_.-]{3,64}") String username,
            @NotBlank @Size(min = 12, max = 128) String password,
            @NotBlank @Size(max = 80) String displayName,
            @NotNull UserAccount.Role role
    ) {}

    public record UpdateRequest(
            @NotBlank @Size(max = 80) String displayName,
            @NotNull UserAccount.Role role,
            boolean enabled,
            @Size(min = 12, max = 128) String newPassword
    ) {}

    public record ProfileUpdateRequest(
            @NotBlank @Size(max = 80) String displayName,
            @Size(min = 12, max = 128) String currentPassword,
            @Size(min = 12, max = 128) String newPassword
    ) {}

    public record View(Long id, String username, String displayName, UserAccount.Role role, boolean enabled, Instant createdAt) {}
}
