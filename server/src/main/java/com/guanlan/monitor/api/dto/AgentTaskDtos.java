package com.guanlan.monitor.api.dto;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.annotation.JsonAnySetter;
import com.fasterxml.jackson.annotation.JsonIgnore;
import com.guanlan.monitor.domain.AgentTask;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;
import jakarta.validation.constraints.Size;

import java.time.Instant;
import java.util.List;
import java.util.LinkedHashSet;
import java.util.Set;

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

    public static final class UpdateRequest {
        @NotBlank @Size(max = 128)
        private String deviceId;
        @NotBlank @Size(max = 8)
        private String action;
        @NotBlank @Size(max = 32)
        private String version;
        @NotNull @Positive
        private Long rolloutId;
        @NotNull @Positive
        private Long memberId;
        private final Set<String> unknownFields = new LinkedHashSet<>();

        public UpdateRequest() {}

        public UpdateRequest(String deviceId, String action, String version, Long rolloutId, Long memberId) {
            this.deviceId = deviceId;
            this.action = action;
            this.version = version;
            this.rolloutId = rolloutId;
            this.memberId = memberId;
        }

        public String deviceId() { return deviceId; }
        public String action() { return action; }
        public String version() { return version; }
        public Long rolloutId() { return rolloutId; }
        public Long memberId() { return memberId; }

        public void setDeviceId(String deviceId) { this.deviceId = deviceId; }
        public void setAction(String action) { this.action = action; }
        public void setVersion(String version) { this.version = version; }
        public void setRolloutId(Long rolloutId) { this.rolloutId = rolloutId; }
        public void setMemberId(Long memberId) { this.memberId = memberId; }

        @JsonAnySetter
        public void unknown(String name, Object ignored) { unknownFields.add(name); }

        @JsonIgnore
        public Set<String> unknownFields() { return Set.copyOf(unknownFields); }
    }

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
