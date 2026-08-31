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
        @Size(max = 100) List<@Valid ContainerStats> containers,
        @Size(max = 256) List<@Valid ProcessStats> processes,
        @Size(max = 128) List<@Valid ServiceStatus> services,
        @Valid FirewallStatus firewall,
        @Size(max = 256) List<@Valid CronJob> cronJobs,
        @Size(max = 64) List<@Valid LogFile> logs,
        @Size(max = 8) List<@Valid LogFile> systemLogs,
        @Size(max = 512) List<@Valid IntegrityItem> integrity,
        @Size(max = 32) List<@Valid CustomMetricResult> customMetrics
) {
    public record HostInfo(
            @NotBlank @Size(max = 255) String hostname, @Size(max = 80) String os, @Size(max = 80) String platform,
            @Size(max = 120) String platformVersion, @Size(max = 255) String kernelVersion,
            @Size(max = 40) String architecture, @PositiveOrZero long uptimeSeconds, @PositiveOrZero long bootTime,
            @Size(max = 256) List<@Valid Temperature> temperatures,
            @Size(max = 256) List<@Valid Fan> fans,
            @Size(max = 32) List<@Valid Battery> batteries,
            @Size(max = 16) List<@Valid Gpu> gpus
    ) {}

    public record Temperature(@Size(max = 255) String sensor,
                               @DecimalMin(value = "-273.15") @DecimalMax(value = "1000.0") double value) {}

    public record Fan(@Size(max = 255) String name, @PositiveOrZero double rpm) {}

    public record Battery(@Size(max = 255) String name, @Min(0) @Max(100) double percent,
                          @Size(max = 80) String status) {}

    public record Gpu(@PositiveOrZero int index, @Size(max = 255) String name,
                      @Min(0) @Max(100) double usagePercent, @PositiveOrZero long memoryUsedBytes,
                      @PositiveOrZero long memoryTotalBytes,
                      @DecimalMin(value = "-273.15") @DecimalMax(value = "1000.0") double temperature) {}

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
            @PositiveOrZero double readBytesPerSec, @PositiveOrZero double writeBytesPerSec,
            @Valid SmartHealth smart
    ) {}

    public record SmartHealth(
            @Size(max = 16) String status, @Size(max = 255) String message,
            @PositiveOrZero long temperature, @PositiveOrZero long powerOnHours,
            @Min(0) @Max(100) long percentageUsed, @PositiveOrZero long mediaErrors,
            @PositiveOrZero long unsafeShutdowns
    ) {}

    public record NetworkStats(@PositiveOrZero double bytesSentPerSec, @PositiveOrZero double bytesRecvPerSec,
                               @PositiveOrZero long bytesSent, @PositiveOrZero long bytesRecv,
                               @PositiveOrZero int tcpConnections) {}

    public record NetworkInterface(@NotBlank @Size(max = 255) String name, @PositiveOrZero int mtu,
                                   @Size(max = 32) String hardwareAddr, @Size(max = 16) List<@NotBlank @Size(max = 40) String> flags,
                                   @Size(max = 64) List<@NotBlank @Size(max = 128) String> addresses) {}

    public record PortStats(@NotBlank @Size(max = 8) String protocol, @NotBlank @Size(max = 128) String address,
                            @PositiveOrZero @Max(65535) int port, @PositiveOrZero int pid) {}

    public record ContainerStats(@NotBlank @Size(max = 96) String id, @NotBlank @Size(max = 255) String name,
                                 @Size(max = 255) String image, @Size(max = 32) String state,
                                 @Size(max = 255) String status, @PositiveOrZero double cpuPercent,
                                 @PositiveOrZero long memoryUsageBytes, @PositiveOrZero long memoryLimitBytes,
                                 @Min(0) @Max(100) double memoryPercent, @PositiveOrZero long networkRxBytes,
                                 @PositiveOrZero long networkTxBytes, @PositiveOrZero int restartCount) {}

    public record ProcessStats(@PositiveOrZero int pid, @Size(max = 255) String name, @Size(max = 2048) String commandLine,
                               @Size(max = 255) String username,
                               @PositiveOrZero double cpuPercent, @Min(0) @Max(100) double memoryPercent,
                               @Size(max = 80) String status) {}

    public record ServiceStatus(@NotBlank @Size(max = 255) String name, @Size(max = 80) String status) {}

    public record FirewallStatus(@Size(max = 40) String provider, @Size(max = 20) String state,
                                 @Size(max = 255) String message) {}

    public record CronJob(@Size(max = 255) String source, @Size(max = 120) String user,
                          @Size(max = 255) String schedule, @Size(max = 500) String command) {}

    public record LogFile(@NotBlank @Size(max = 1024) String path, @PositiveOrZero long sizeBytes,
                          @Size(max = 40) String modifiedAt,
                          @Size(max = 20) List<@Size(max = 500) String> lines) {}

    public record IntegrityItem(@NotBlank @Size(max = 1024) String path, @Size(max = 64) String sha256,
                                @PositiveOrZero long sizeBytes, @Size(max = 40) String modifiedAt) {}

    public record CustomMetricResult(@NotBlank @Size(max = 80) String name,
                                     @NotBlank @Size(max = 20) String kind,
                                     Double value, @Size(max = 4096) String text,
                                     int exitCode, boolean success, @Size(max = 4096) String error) {}
}
