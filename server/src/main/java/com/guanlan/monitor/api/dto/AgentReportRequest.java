package com.guanlan.monitor.api.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.DecimalMax;
import jakarta.validation.constraints.DecimalMin;
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
        @Size(max = 512) List<@Valid NetworkInterface> networkInterfaces,
        @Size(max = 512) List<@Valid PortStats> ports,
        @Size(max = 256) List<@Valid ProcessStats> processes,
        @Size(max = 128) List<@Valid ServiceStatus> services
) {
    public record HostInfo(
            @NotBlank @Size(max = 255) String hostname, @Size(max = 80) String os, @Size(max = 80) String platform,
            @Size(max = 120) String platformVersion, @Size(max = 255) String kernelVersion,
            @Size(max = 40) String architecture, @PositiveOrZero long uptimeSeconds, @PositiveOrZero long bootTime,
            @Size(max = 256) List<@Valid Temperature> temperatures
    ) {}

    public record Temperature(@Size(max = 255) String sensor,
                               @DecimalMin(value = "-273.15") @DecimalMax(value = "1000.0") double value) {}

    public record CpuStats(
            @Size(max = 255) String model, @PositiveOrZero int logicalCores, @PositiveOrZero int physicalCores,
            @Min(0) @Max(100) double usagePercent, @Size(max = 1024) List<@NotNull @Min(0) @Max(100) Double> perCorePercent,
            @PositiveOrZero double load1, @PositiveOrZero double load5, @PositiveOrZero double load15
    ) {}

    public record MemoryStats(
            @PositiveOrZero long totalBytes, @PositiveOrZero long usedBytes, @PositiveOrZero long availableBytes,
            @Min(0) @Max(100) double usagePercent,
            @PositiveOrZero long cachedBytes, @PositiveOrZero long swapTotalBytes, @PositiveOrZero long swapUsedBytes,
            @Min(0) @Max(100) double swapPercent
    ) {}

    public record DiskStats(
            @Size(max = 255) String device, @Size(max = 255) String mountpoint, @Size(max = 80) String fileSystem,
            @PositiveOrZero long totalBytes, @PositiveOrZero long usedBytes, @PositiveOrZero long freeBytes,
            @Min(0) @Max(100) double usagePercent,
            @PositiveOrZero double readBytesPerSec, @PositiveOrZero double writeBytesPerSec
    ) {}

    public record NetworkStats(@PositiveOrZero double bytesSentPerSec, @PositiveOrZero double bytesRecvPerSec,
                               @PositiveOrZero long bytesSent, @PositiveOrZero long bytesRecv,
                               @PositiveOrZero int tcpConnections) {}

    public record NetworkInterface(@NotBlank @Size(max = 255) String name, @PositiveOrZero int mtu,
                                   @Size(max = 32) String hardwareAddr, @Size(max = 16) List<@NotBlank @Size(max = 40) String> flags,
                                   @Size(max = 64) List<@NotBlank @Size(max = 128) String> addresses) {}

    public record PortStats(@NotBlank @Size(max = 8) String protocol, @NotBlank @Size(max = 128) String address,
                            @PositiveOrZero int port, @PositiveOrZero int pid) {}

    public record ProcessStats(@PositiveOrZero int pid, @Size(max = 255) String name, @Size(max = 255) String username,
                               @PositiveOrZero double cpuPercent, @Min(0) @Max(100) double memoryPercent,
                               @Size(max = 80) String status) {}

    public record ServiceStatus(@NotBlank @Size(max = 255) String name, @Size(max = 80) String status) {}
}
