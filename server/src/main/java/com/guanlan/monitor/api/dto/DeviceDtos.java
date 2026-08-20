package com.guanlan.monitor.api.dto;

import com.guanlan.monitor.domain.Device;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

import java.time.Instant;
import java.util.Map;

public final class DeviceDtos {
    private DeviceDtos() {}

    public record CreateRequest(
            @NotBlank @Size(max = 100) String name,
            @Size(max = 120) String location,
            @Size(max = 80) String groupName,
            @Size(max = 64) String primaryIp
    ) {}

    public record UpdateRequest(
            @NotBlank @Size(max = 100) String name,
            @Size(max = 120) String location,
            @Size(max = 80) String groupName,
            @Size(max = 64) String primaryIp
    ) {}

    public record View(
            String id, String name, String hostname, String os, String architecture,
            String primaryIp, String location, String groupName, Device.Status status,
            Instant lastSeenAt, String agentKeyPrefix, boolean controllerManaged, Instant createdAt, Map<String, Object> hardware, MetricView latest
    ) {}

    public record Credential(View device, String agentKey) {}
}
