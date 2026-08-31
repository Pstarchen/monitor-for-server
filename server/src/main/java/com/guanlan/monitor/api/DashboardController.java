package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.AlertDtos;
import com.guanlan.monitor.api.dto.DeviceDtos;
import com.guanlan.monitor.domain.AlertEvent;
import com.guanlan.monitor.domain.Device;
import com.guanlan.monitor.repository.AlertEventRepository;
import com.guanlan.monitor.service.AlertService;
import com.guanlan.monitor.service.DeviceService;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.security.core.Authentication;
import com.guanlan.monitor.service.DeviceAccessService;

import java.util.Comparator;
import java.util.List;

@RestController
@RequestMapping("/api/dashboard")
@RequiredArgsConstructor
public class DashboardController {
    private final AlertEventRepository alertRepository;
    private final DeviceService deviceService;
    private final AlertService alertService;
    private final DeviceAccessService access;

    @GetMapping
    DashboardView get(Authentication authentication) {
        List<DeviceDtos.View> allDevices = deviceService.list();
        var visible = access.visibleDeviceIds(authentication);
        List<DeviceDtos.View> devices = visible == null ? allDevices
                : allDevices.stream().filter(device -> visible.contains(device.id())).toList();
        List<DeviceDtos.View> measured = devices.stream()
                .filter(device -> device.status() == Device.Status.ONLINE && device.latest() != null).toList();
        List<DeviceDtos.View> top = measured.stream()
                .sorted(Comparator.comparingDouble(this::peakResourceUsage).reversed())
                .limit(5).toList();
        return new DashboardView(
                devices.size(),
                devices.stream().filter(device -> device.status() == Device.Status.ONLINE).count(),
                devices.stream().filter(device -> device.status() == Device.Status.OFFLINE).count(),
                devices.stream().filter(device -> device.status() == Device.Status.PENDING).count(),
                activeAlerts(authentication, devices),
                average(measured, "cpu"), average(measured, "memory"), average(measured, "disk"),
                measured.stream().mapToDouble(device -> device.latest().networkSentBps()).sum(),
                measured.stream().mapToDouble(device -> device.latest().networkRecvBps()).sum(),
                measured.stream().mapToInt(device -> device.latest().smartFailed()).sum(),
                measured.stream().mapToInt(device -> device.latest().integrityChanges()).sum(),
                measured.stream().mapToInt(device -> device.latest().firewallInactive() == null ? 0 : device.latest().firewallInactive()).sum(),
                devices, top, recentAlerts(authentication)
        );
    }

    private long activeAlerts(Authentication authentication, List<DeviceDtos.View> devices) {
        List<AlertEvent.Status> active = List.of(AlertEvent.Status.OPEN, AlertEvent.Status.ACKNOWLEDGED);
        if (access.visibleDeviceIds(authentication) == null) {
            return alertRepository.countByStatusIn(active);
        }
        List<String> ids = devices.stream().map(DeviceDtos.View::id).toList();
        return ids.isEmpty() ? 0 : alertRepository.countByDeviceIdInAndStatusIn(ids, active);
    }

    private List<AlertDtos.EventView> recentAlerts(Authentication authentication) {
        List<AlertDtos.EventView> alerts = alertService.listEvents(500);
        var visible = access.visibleDeviceIds(authentication);
        if (visible != null) alerts = alerts.stream().filter(alert -> visible.contains(alert.deviceId())).toList();
        return alerts.stream().limit(6).toList();
    }

    private double average(List<DeviceDtos.View> devices, String metric) {
        return devices.stream().mapToDouble(device -> switch (metric) {
            case "cpu" -> device.latest().cpuUsage();
            case "memory" -> device.latest().memoryUsage();
            default -> device.latest().diskUsage();
        }).average().orElse(0);
    }

    private double peakResourceUsage(DeviceDtos.View device) {
        var latest = device.latest();
        return Math.max(latest.cpuUsage(), Math.max(latest.memoryUsage(), latest.diskUsage()));
    }

    public record DashboardView(
            long totalDevices, long onlineDevices, long offlineDevices, long pendingDevices, long activeAlerts,
            double averageCpu, double averageMemory, double averageDisk,
            double networkSentBps, double networkRecvBps,
            long smartFailures, long integrityChanges, long firewallInactive,
            List<DeviceDtos.View> devices, List<DeviceDtos.View> topDevices, List<AlertDtos.EventView> recentAlerts
    ) {}
}
