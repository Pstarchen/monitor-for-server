package com.guanlan.monitor.api.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

import java.time.Instant;
import java.util.List;

public record AgentReportRequest(
        @NotNull Instant collectedAt,
        @NotNull @Valid HostInfo host,
        @NotNull @Valid CpuStats cpu,
        @NotNull @Valid MemoryStats memory,
        List<DiskStats> disks,
        @NotNull @Valid NetworkStats network,
        List<ProcessStats> processes,
        List<ServiceStatus> services
) {
    public record HostInfo(
            @NotBlank String hostname, String os, String platform, String platformVersion,
            String kernelVersion, String architecture, long uptimeSeconds, long bootTime,
            List<Temperature> temperatures
    ) {}

    public record Temperature(String sensor, double value) {}

    public record CpuStats(
            String model, int logicalCores, int physicalCores,
            @Min(0) @Max(100) double usagePercent,
            List<Double> perCorePercent, double load1, double load5, double load15
    ) {}

    public record MemoryStats(
            long totalBytes, long usedBytes, long availableBytes,
            @Min(0) @Max(100) double usagePercent,
            long cachedBytes, long swapTotalBytes, long swapUsedBytes,
            @Min(0) @Max(100) double swapPercent
    ) {}

    public record DiskStats(
            String device, String mountpoint, String fileSystem, long totalBytes,
            long usedBytes, long freeBytes, double usagePercent,
            double readBytesPerSec, double writeBytesPerSec
    ) {}

    public record NetworkStats(double bytesSentPerSec, double bytesRecvPerSec, int tcpConnections) {}

    public record ProcessStats(int pid, String name, String username, double cpuPercent, double memoryPercent, String status) {}

    public record ServiceStatus(String name, String status) {}
}

