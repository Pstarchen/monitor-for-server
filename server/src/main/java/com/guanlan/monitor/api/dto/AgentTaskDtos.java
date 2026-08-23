package com.guanlan.monitor.api.dto;

import com.fasterxml.jackson.databind.JsonNode;
import com.guanlan.monitor.domain.AgentTask;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.time.Instant;
import java.util.List;

public final class AgentTaskDtos {
    private AgentTaskDtos() {}

    public record CreateRequest(
            @NotBlank @Size(max = 128) String deviceId,
            @NotBlank @Size(max = 128) String command,
            @NotNull @Size(max = 32) List<@NotBlank @Size(max = 256) String> args,
            @Min(1) @Max(300) Integer timeoutSeconds,
            @Min(1024) @Max(1_048_576) Integer maxOutputBytes
    ) {}

    public record FileRequest(
            @NotBlank @Size(max = 128) String deviceId,
            @NotBlank @Size(max = 4096) String path,
            @Size(max = 1_500_000) String content,
            @Size(max = 10) String encoding,
            @Min(0) Long offset,
            @Min(1) @Max(1_048_576) Integer length,
            Boolean showHidden,
            Boolean recursive,
            Boolean createDirs,
            @Size(max = 16) String mode,
            @Size(max = 64) String ifMatchSha256,
            @Min(1) @Max(300) Integer timeoutSeconds,
            @Min(1024) @Max(1_048_576) Integer maxOutputBytes
    ) {}

    public record ResultRequest(
            @NotBlank @Size(max = 20) String status,
            @Min(-1) Integer exitCode,
            @Size(max = 1_048_576) String stdout,
            @Size(max = 1_048_576) String stderr,
            @Size(max = 500) String error
    ) {}

    public record View(
            Long id,
            String deviceId,
            String deviceName,
            AgentTask.Operation operation,
            String command,
            List<String> args,
            int timeoutSeconds,
            int maxOutputBytes,
            AgentTask.Status status,
            String createdBy,
            Instant createdAt,
            Instant startedAt,
            Instant finishedAt,
            Integer exitCode,
            String stdout,
            String stderr,
            String error
    ) {}

    public record Assignment(
            Long id,
            AgentTask.Operation operation,
            String command,
            List<String> args,
            int timeoutSeconds,
            int maxOutputBytes,
            JsonNode payload
    ) {}
}
