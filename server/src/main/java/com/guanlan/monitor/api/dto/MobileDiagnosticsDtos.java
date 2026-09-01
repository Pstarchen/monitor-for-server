package com.guanlan.monitor.api.dto;

import java.time.Instant;
import java.util.List;

public final class MobileDiagnosticsDtos {
    private MobileDiagnosticsDtos() {}

    public record Diagnostics(
            String deviceId,
            Instant collectedAt,
            boolean online,
            Totals totals,
            List<NetworkInterface> networkInterfaces,
            List<Disk> disks,
            List<Process> topCpuProcesses,
            List<Process> topMemoryProcesses,
            Health health
    ) {}

    public record Totals(
            double cpuUsage,
            double memoryUsage,
            double swapUsage,
            double load1,
            double load5,
            double load15,
            double temperatureCelsius,
            double networkSentBps,
            double networkRecvBps,
            long networkSentBytes,
            long networkRecvBytes,
            int tcpConnections
    ) {}

    public record NetworkInterface(String name, int mtu, List<String> flags, List<String> addresses) {}

    public record Disk(
            String device,
            String mountpoint,
            String fileSystem,
            long totalBytes,
            long usedBytes,
            long freeBytes,
            double usagePercent,
            double readBytesPerSec,
            double writeBytesPerSec,
            Smart smart
    ) {}

    public record Smart(boolean available, boolean healthy, String status, long temperatureCelsius) {}

    public record Process(
            int pid,
            String name,
            String username,
            double cpuPercent,
            double memoryPercent,
            String status
    ) {}

    public record Health(
            boolean smartFailure,
            boolean integrityChanged,
            boolean firewallEnabled,
            List<String> messages
    ) {}

    public record History(
            String deviceId,
            String range,
            Instant from,
            Instant to,
            long sampleStepSeconds,
            List<HistoryPoint> points
    ) {}

    public record HistoryPoint(
            Instant collectedAt,
            double cpuUsage,
            double memoryUsage,
            double swapUsage,
            double load1,
            double load5,
            double load15,
            double temperatureCelsius,
            double diskUsage,
            double networkSentBps,
            double networkRecvBps
    ) {}
}
