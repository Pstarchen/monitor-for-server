package com.guanlan.monitor.api.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

import java.time.Instant;

public final class DeviceNoteDtos {
    private DeviceNoteDtos() {}

    public record CreateRequest(@NotBlank @Size(max = 2000) String content) {}

    public record View(Long id, String deviceId, String deviceName, String author, String content, Instant createdAt) {}
}
