package com.guanlan.monitor.service;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.api.dto.DeviceDtos;
import com.guanlan.monitor.domain.AlertEvent;
import com.guanlan.monitor.domain.ServiceCheck;
import com.guanlan.monitor.domain.ServiceCheckResult;
import com.guanlan.monitor.repository.AlertEventRepository;
import com.guanlan.monitor.repository.MetricSnapshotRepository;
import com.guanlan.monitor.repository.ServiceCheckRepository;
import com.guanlan.monitor.repository.ServiceCheckResultRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Set;

@Service
@RequiredArgsConstructor
public class ReportService {
    private final DeviceService devices;
    private final MetricSnapshotRepository metrics;
    private final ServiceCheckRepository checks;
    private final ServiceCheckResultRepository results;
    private final AlertEventRepository alerts;

    @Transactional(readOnly = true)
    public Summary summary(Instant from, Instant to, Set<String> allowedDeviceIds) {
        Instant end = to == null ? Instant.now() : to;
        Instant start = from == null ? end.minus(Duration.ofDays(7)) : from;
        if (start.isAfter(end) || Duration.between(start, end).toDays() > 31) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "报告时间范围无效或超过 31 天");
        }
        List<DeviceReport> deviceReports = devices.list().stream()
                .filter(device -> allowedDeviceIds == null || allowedDeviceIds.contains(device.id()))
                .map(device -> deviceReport(device, start, end))
                .toList();
        List<AlertEvent> periodAlerts = alerts.findByStartedAtBetweenOrderByStartedAtDesc(start, end).stream()
                .filter(alert -> allowedDeviceIds == null || allowedDeviceIds.contains(alert.getDevice().getId()))
                .toList();
        List<ServiceReport> serviceReports = checks.findAllByOrderBySortOrderDescNameAsc().stream()
                .map(check -> serviceReport(check, start, end))
                .toList();
        long online = deviceReports.stream().filter(device -> "ONLINE".equals(device.status())).count();
        long activeAlerts = periodAlerts.stream().filter(alert -> alert.getStatus() != AlertEvent.Status.RESOLVED).count();
        return new Summary(start, end, Instant.now(), deviceReports.size(), online, deviceReports.size() - online,
                periodAlerts.size(), activeAlerts, deviceReports, serviceReports);
    }

    private DeviceReport deviceReport(DeviceDtos.View device, Instant from, Instant to) {
        var samples = metrics.findByDeviceIdAndCollectedAtBetweenOrderByCollectedAtAsc(device.id(), from, to);
        double avgCpu = samples.stream().mapToDouble(item -> item.getCpuUsage()).average().orElse(0);
        double avgMemory = samples.stream().mapToDouble(item -> item.getMemoryUsage()).average().orElse(0);
        double avgDisk = samples.stream().mapToDouble(item -> item.getDiskUsage()).average().orElse(0);
        double peak = samples.stream().mapToDouble(item -> Math.max(item.getCpuUsage(), Math.max(item.getMemoryUsage(), item.getDiskUsage()))).max().orElse(0);
        return new DeviceReport(device.id(), device.name(), device.status().name(), samples.size(), round(avgCpu), round(avgMemory), round(avgDisk), round(peak));
    }

    private ServiceReport serviceReport(ServiceCheck check, Instant from, Instant to) {
        List<ServiceCheckResult> period = results.findByServiceCheckIdAndCheckedAtBetweenOrderByCheckedAtAsc(check.getId(), from, to);
        long successful = period.stream().filter(ServiceCheckResult::isSuccess).count();
        double availability = period.isEmpty() ? 0 : round(successful * 100d / period.size());
        double averageLatency = period.stream().filter(ServiceCheckResult::isSuccess).mapToLong(ServiceCheckResult::getLatencyMs).average().orElse(0);
        long incidents = period.stream().filter(result -> !result.isSuccess()).count();
        return new ServiceReport(check.getId(), check.getName(), check.getType().name(), period.size(), availability, round(averageLatency), incidents);
    }

    private double round(double value) { return Math.round(value * 100d) / 100d; }

    public record Summary(Instant from, Instant to, Instant generatedAt, long totalDevices, long onlineDevices,
                          long offlineDevices, long alertCount, long activeAlertCount, List<DeviceReport> devices,
                          List<ServiceReport> services) {}

    public record DeviceReport(String id, String name, String status, int samples, double averageCpu,
                               double averageMemory, double averageDisk, double peakPressure) {}

    public record ServiceReport(Long id, String name, String type, int samples, double availabilityPercent,
                                double averageLatencyMs, long incidents) {}
}
