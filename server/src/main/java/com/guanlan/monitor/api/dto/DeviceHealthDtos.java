package com.guanlan.monitor.api.dto;

import com.guanlan.monitor.domain.Device;

import java.time.Instant;
import java.util.List;

/**
 * Operator-facing explanation of the current Agent connection state.
 * This deliberately contains no credential or network-secret material.
 */
public final class DeviceHealthDtos {
    private DeviceHealthDtos() {}

    public record View(
            Device.Status deviceStatus,
            State state,
            String reasonCode,
            String reason,
            Severity severity,
            Instant lastSeenAt,
            Long lastSeenAgeSeconds,
            int offlineAfterSeconds,
            Instant latestCollectedAt,
            Long dataAgeSeconds,
            Instant expectedBy,
            List<Check> checks
    ) {}

    public record Check(String code, CheckState state, String label, String detail) {}

    public enum State { HEALTHY, PENDING, OFFLINE, DEGRADED }
    public enum Severity { INFO, WARNING, CRITICAL }
    public enum CheckState { PASS, PENDING, WARN, FAIL }
}
