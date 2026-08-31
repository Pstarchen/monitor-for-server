package com.guanlan.monitor.api.dto;

import com.guanlan.monitor.domain.Device;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;

public final class DeviceDtos {
    private DeviceDtos() {}

    public record CreateRequest(
            @NotBlank @Size(max = 100) String name,
            @Size(max = 120) String location,
            @Size(max = 80) String groupName,
            @Size(max = 64) String primaryIp,
            boolean ddnsEnabled,
            Long ddnsConfigId,
            boolean publicVisible,
            @Size(max = 20) List<@Size(max = 40) String> tags,
            @Size(max = 80) String assetTag,
            @Size(max = 100) String ownerName,
            @Size(max = 100) String vendor,
            @Size(max = 120) String model,
            @Size(max = 120) String serialNumber,
            @Size(max = 40) String environment,
            LocalDate purchaseDate,
            LocalDate warrantyExpiresAt,
            @Size(max = 500) String description
    ) {
        public CreateRequest(String name, String location, String groupName, String primaryIp) {
            this(name, location, groupName, primaryIp, false, null, true, List.of(), null, null, null, null, null, null, null, null, null);
        }
    }

    public record UpdateRequest(
            @NotBlank @Size(max = 100) String name,
            @Size(max = 120) String location,
            @Size(max = 80) String groupName,
            @Size(max = 64) String primaryIp,
            boolean ddnsEnabled,
            Long ddnsConfigId,
            boolean publicVisible,
            @Size(max = 20) List<@Size(max = 40) String> tags,
            @Size(max = 80) String assetTag,
            @Size(max = 100) String ownerName,
            @Size(max = 100) String vendor,
            @Size(max = 120) String model,
            @Size(max = 120) String serialNumber,
            @Size(max = 40) String environment,
            LocalDate purchaseDate,
            LocalDate warrantyExpiresAt,
            @Size(max = 500) String description
    ) {
        public UpdateRequest(String name, String location, String groupName, String primaryIp) {
            this(name, location, groupName, primaryIp, false, null, true, List.of(), null, null, null, null, null, null, null, null, null);
        }
        public UpdateRequest(String name, String location, String groupName, String primaryIp, boolean ddnsEnabled, Long ddnsConfigId) {
            this(name, location, groupName, primaryIp, ddnsEnabled, ddnsConfigId, true, List.of(), null, null, null, null, null, null, null, null, null);
        }
        public UpdateRequest(String name, String location, String groupName, String primaryIp, boolean ddnsEnabled, Long ddnsConfigId, boolean publicVisible) {
            this(name, location, groupName, primaryIp, ddnsEnabled, ddnsConfigId, publicVisible, List.of(), null, null, null, null, null, null, null, null, null);
        }
    }

    public record View(
            String id, String name, String hostname, String os, String architecture,
            String primaryIp, String location, String groupName, List<String> tags,
            String assetTag, String ownerName, String vendor, String model, String serialNumber, String environment,
            LocalDate purchaseDate, LocalDate warrantyExpiresAt, String description,
            boolean ddnsEnabled, Long ddnsConfigId, boolean publicVisible, Device.Status status,
            Instant lastSeenAt, String agentKeyPrefix, boolean controllerManaged, Instant createdAt, Map<String, Object> hardware, MetricView latest,
            DeviceHealthDtos.View health
    ) {}

    public record Credential(View device, String agentKey) {}
}
