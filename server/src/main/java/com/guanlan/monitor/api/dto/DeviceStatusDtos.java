package com.guanlan.monitor.api.dto;

import com.guanlan.monitor.domain.Device;

import java.time.Instant;

public final class DeviceStatusDtos {
    private DeviceStatusDtos() {}

    public record View(Long id, Device.Status previousStatus, Device.Status status, String reason, Instant changedAt) {}
}
