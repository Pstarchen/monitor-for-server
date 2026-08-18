package com.guanlan.monitor.api.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.PositiveOrZero;
import jakarta.validation.constraints.Size;

import java.time.Instant;
import java.util.List;

public record AgentReportRequest(
        @NotNull Instant collectedAt,
        @NotNull @Valid HostInfo host,
        @NotNull @Valid CpuStats cpu,
        @NotNull @Valid MemoryStats memory,
        @Size(max = 256) List<@Valid DiskStats> disks,
        @NotNull @Valid NetworkStats network,
        @Size(max = 256) List<@Valid ProcessStats> processes,
        @Size(max = 128) List<@Valid ServiceStatus> services
) {
    public record HostInfo(
            @NotBlank @Size(max = 255) String hostname, @Size(max = 80) String os, @Size(max = 80) String platform,
            @Size(max = 120) String platformVersion, @Size(max = 255) String kernelVersion,
            @Size(max = 40) String architecture, @PositiveOrZero long uptimeSeconds, @PositiveOrZero long bootTime,
            @Size(max = 256) List<@Valid Temperature> temperatures
    ) {}

    public record Temperature(@Size(max = 255) String sensor, double value) {}

    public record CpuStats(
            @Size(max = 255) String model, @PositiveOrZero int logicalCores, @PositiveOrZero int physicalCores,
            @Min(0) @Max(100) double usagePercent, @Size(max = 1024) List<Double> perCorePercent,
            @PositiveOrZero double load1, @PositiveOrZero double load5, @PositiveOrZero double load15
    ) {}

    public record MemoryStats(
            long totalBytes, long usedBytes, long availableBytes,
            @Min(0) @Max(100) double usagePercent,
            long cachedBytes, long swapTotalBytes, long swapUsedBytes,
            @Min(0) @Max(100) double swapPercent
    ) {}

    public record DiskStats(
            @Size(max = 255) String device, @Size(max = 255) String mountpoint, @Size(max = 80) String fileSystem,
            @PositiveOrZero long totalBytes, @PositiveOrZero long usedBytes, @PositiveOrZero long freeBytes,
            @Min(0) @Max(100) double usagePercent,
            @PositiveOrZero double readBytesPerSec, @PositiveOrZero double writeBytesPerSec
    ) {}

    public record NetworkStats(@PositiveOrZero double bytesSentPerSec, @PositiveOrZero double bytesRecvPerSec,
                               @PositiveOrZero int tcpConnections) {}

    public record ProcessStats(@PositiveOrZero int pid, @Size(max = 255) String name, @Size(max = 255) String username,
                               @Min(0) @Max(100) double cpuPercent, @Min(0) @Max(100) double memoryPercent,
                               @Size(max = 80) String status) {}

    public record ServiceStatus(@NotBlank @Size(max = 255) String name, @Size(max = 80) String status) {}
}
