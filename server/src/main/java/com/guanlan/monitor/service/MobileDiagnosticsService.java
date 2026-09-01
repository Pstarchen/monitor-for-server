package com.guanlan.monitor.service;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.api.dto.AgentReportRequest;
import com.guanlan.monitor.api.dto.DeviceDtos;
import com.guanlan.monitor.api.dto.MetricView;
import com.guanlan.monitor.api.dto.MobileDiagnosticsDtos;
import com.guanlan.monitor.domain.Device;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;

import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.Objects;

@Service
@RequiredArgsConstructor
public class MobileDiagnosticsService {
    private static final int MAX_HISTORY_POINTS = 720;
    private static final int TOP_PROCESS_LIMIT = 5;

    private final DeviceService devices;
    private final MetricService metrics;

    public MobileDiagnosticsDtos.Diagnostics diagnostics(String deviceId) {
        DeviceDtos.View device = devices.get(deviceId);
        MetricView metric = metrics.latest(deviceId);
        List<MobileDiagnosticsDtos.Disk> disks = metric.disks().stream()
                .filter(Objects::nonNull).map(this::disk).toList();
        List<MobileDiagnosticsDtos.Process> processes = metric.processes().stream()
                .filter(Objects::nonNull).map(this::process).toList();

        return new MobileDiagnosticsDtos.Diagnostics(
                deviceId,
                metric.collectedAt(),
                device.status() == Device.Status.ONLINE,
                new MobileDiagnosticsDtos.Totals(
                        metric.cpuUsage(), metric.memoryUsage(), metric.swapUsage(),
                        metric.load1(), metric.load5(), metric.load15(), metric.temperatureMax(),
                        metric.networkSentBps(), metric.networkRecvBps(),
                        metric.networkSentBytes(), metric.networkRecvBytes(), metric.tcpConnections()),
                metric.networkInterfaces().stream()
                        .filter(Objects::nonNull).map(this::networkInterface).toList(),
                disks,
                topProcesses(processes, Comparator.comparingDouble(MobileDiagnosticsDtos.Process::cpuPercent).reversed()),
                topProcesses(processes, Comparator.comparingDouble(MobileDiagnosticsDtos.Process::memoryPercent).reversed()),
                health(metric, disks)
        );
    }

    public MobileDiagnosticsDtos.History history(String deviceId, String requestedRange) {
        HistoryRange range = HistoryRange.parse(requestedRange);
        Instant to = Instant.now();
        Instant from = to.minus(range.duration);
        List<MetricView> raw = metrics.history(deviceId, from, to);
        List<MobileDiagnosticsDtos.HistoryPoint> points = downsample(raw, from, range.sampleStepSeconds);
        return new MobileDiagnosticsDtos.History(
                deviceId, range.wireValue, from, to, range.sampleStepSeconds, points);
    }

    private List<MobileDiagnosticsDtos.HistoryPoint> downsample(List<MetricView> raw, Instant from,
                                                                 long sampleStepSeconds) {
        if (raw.isEmpty()) return List.of();
        List<MobileDiagnosticsDtos.HistoryPoint> points = new ArrayList<>();
        long activeBucket = Long.MIN_VALUE;
        MetricView activeMetric = null;
        for (MetricView metric : raw) {
            long secondsFromStart = Math.max(0, Duration.between(from, metric.collectedAt()).getSeconds());
            long bucket = secondsFromStart / sampleStepSeconds;
            if (activeMetric != null && bucket != activeBucket) {
                points.add(historyPoint(activeMetric));
                if (points.size() == MAX_HISTORY_POINTS) return List.copyOf(points);
            }
            activeBucket = bucket;
            activeMetric = metric;
        }
        if (activeMetric != null && points.size() < MAX_HISTORY_POINTS) points.add(historyPoint(activeMetric));
        return List.copyOf(points);
    }

    private MobileDiagnosticsDtos.HistoryPoint historyPoint(MetricView metric) {
        return new MobileDiagnosticsDtos.HistoryPoint(
                metric.collectedAt(), metric.cpuUsage(), metric.memoryUsage(), metric.swapUsage(),
                metric.load1(), metric.load5(), metric.load15(), metric.temperatureMax(),
                metric.diskUsage(), metric.networkSentBps(), metric.networkRecvBps());
    }

    private MobileDiagnosticsDtos.NetworkInterface networkInterface(AgentReportRequest.NetworkInterface item) {
        return new MobileDiagnosticsDtos.NetworkInterface(
                text(item.name()), item.mtu(), safeList(item.flags()), safeList(item.addresses()));
    }

    private MobileDiagnosticsDtos.Disk disk(AgentReportRequest.DiskStats item) {
        AgentReportRequest.SmartHealth source = item.smart();
        String status = source == null ? "UNKNOWN" : text(source.status()).toUpperCase(Locale.ROOT);
        if (status.isBlank()) status = "UNKNOWN";
        MobileDiagnosticsDtos.Smart smart = new MobileDiagnosticsDtos.Smart(
                source != null, "PASSED".equals(status), status, source == null ? 0 : source.temperature());
        return new MobileDiagnosticsDtos.Disk(
                text(item.device()), text(item.mountpoint()), text(item.fileSystem()),
                item.totalBytes(), item.usedBytes(), item.freeBytes(), item.usagePercent(),
                item.readBytesPerSec(), item.writeBytesPerSec(), smart);
    }

    private MobileDiagnosticsDtos.Process process(AgentReportRequest.ProcessStats item) {
        return new MobileDiagnosticsDtos.Process(
                item.pid(), text(item.name()), text(item.username()), item.cpuPercent(),
                item.memoryPercent(), text(item.status()));
    }

    private List<MobileDiagnosticsDtos.Process> topProcesses(List<MobileDiagnosticsDtos.Process> processes,
                                                              Comparator<MobileDiagnosticsDtos.Process> comparator) {
        return processes.stream().sorted(comparator).limit(TOP_PROCESS_LIMIT).toList();
    }

    private MobileDiagnosticsDtos.Health health(MetricView metric, List<MobileDiagnosticsDtos.Disk> disks) {
        boolean smartFailure = metric.smartFailed() > 0 || disks.stream()
                .anyMatch(disk -> "FAILED".equals(disk.smart().status()));
        boolean integrityChanged = metric.integrityChanges() > 0;
        boolean firewallEnabled = metric.firewall() != null &&
                "ACTIVE".equalsIgnoreCase(metric.firewall().state());
        List<String> messages = new ArrayList<>();
        if (smartFailure) messages.add("磁盘 SMART 检测到异常");
        if (integrityChanged) messages.add("关键文件完整性发生变化");
        if (metric.firewall() != null && !firewallEnabled) messages.add("主机防火墙未启用");
        return new MobileDiagnosticsDtos.Health(
                smartFailure, integrityChanged, firewallEnabled, List.copyOf(messages));
    }

    private String text(String value) {
        return value == null ? "" : value;
    }

    private List<String> safeList(List<String> values) {
        return values == null ? List.of() : values.stream().filter(Objects::nonNull).toList();
    }

    private enum HistoryRange {
        ONE_HOUR("1H", Duration.ofHours(1), 60),
        SIX_HOURS("6H", Duration.ofHours(6), 300),
        ONE_DAY("24H", Duration.ofHours(24), 900),
        SEVEN_DAYS("7D", Duration.ofDays(7), 1_800),
        THIRTY_DAYS("30D", Duration.ofDays(30), 3_600);

        private final String wireValue;
        private final Duration duration;
        private final long sampleStepSeconds;

        HistoryRange(String wireValue, Duration duration, long sampleStepSeconds) {
            this.wireValue = wireValue;
            this.duration = duration;
            this.sampleStepSeconds = sampleStepSeconds;
        }

        private static HistoryRange parse(String value) {
            for (HistoryRange range : values()) {
                if (range.wireValue.equalsIgnoreCase(value == null ? "" : value.trim())) return range;
            }
            throw new ApiException(HttpStatus.BAD_REQUEST, "历史范围仅支持 1H、6H、24H、7D、30D");
        }
    }
}
