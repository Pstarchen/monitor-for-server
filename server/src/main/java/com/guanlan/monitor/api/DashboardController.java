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
import com.guanlan.monitor.security.ApiTokenPrincipal;

import java.util.Comparator;
import java.util.List;

@RestController
@RequestMapping("/api/dashboard")
@RequiredArgsConstructor
public class DashboardController {
    private final AlertEventRepository alertRepository;
    private final DeviceService deviceService;
    private final AlertService alertService;

    @GetMapping
    DashboardView get(Authentication authentication) {
        List<DeviceDtos.View> allDevices = deviceService.list();
        List<DeviceDtos.View> devices = allDevices.stream().filter(device -> visible(authentication, device.id())).toList();
        List<DeviceDtos.View> measured = devices.stream()
                .filter(device -> device.status() == Device.Status.ONLINE && device.latest() != null).toList();
        List<DeviceDtos.View> top = measured.stream()
                .sorted(Comparator.comparingDouble((DeviceDtos.View device) -> device.latest().cpuUsage()).reversed())
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
                devices, top, recentAlerts(authentication)
        );
    }

    private boolean visible(Authentication authentication, String deviceId) {
        return !(authentication != null && authentication.getPrincipal() instanceof ApiTokenPrincipal principal
                && !principal.serverIds().isEmpty())
                || ((ApiTokenPrincipal) authentication.getPrincipal()).serverIds().contains(deviceId);
    }

    private long activeAlerts(Authentication authentication, List<DeviceDtos.View> devices) {
        List<AlertEvent.Status> active = List.of(AlertEvent.Status.OPEN, AlertEvent.Status.ACKNOWLEDGED);
        if (!(authentication != null && authentication.getPrincipal() instanceof ApiTokenPrincipal principal) || principal.serverIds().isEmpty()) {
            return alertRepository.countByStatusIn(active);
        }
        List<String> ids = devices.stream().map(DeviceDtos.View::id).toList();
        return ids.isEmpty() ? 0 : alertRepository.countByDeviceIdInAndStatusIn(ids, active);
    }

    private List<AlertDtos.EventView> recentAlerts(Authentication authentication) {
        List<AlertDtos.EventView> alerts = alertService.listEvents(500);
        if (authentication != null && authentication.getPrincipal() instanceof ApiTokenPrincipal principal && !principal.serverIds().isEmpty()) {
            alerts = alerts.stream().filter(alert -> principal.serverIds().contains(alert.deviceId())).toList();
        }
        return alerts.stream().limit(6).toList();
    }

    private double average(List<DeviceDtos.View> devices, String metric) {
        return devices.stream().mapToDouble(device -> switch (metric) {
            case "cpu" -> device.latest().cpuUsage();
            case "memory" -> device.latest().memoryUsage();
            default -> device.latest().diskUsage();
        }).average().orElse(0);
    }

    public record DashboardView(
            long totalDevices, long onlineDevices, long offlineDevices, long pendingDevices, long activeAlerts,
            double averageCpu, double averageMemory, double averageDisk,
            double networkSentBps, double networkRecvBps,
            List<DeviceDtos.View> devices, List<DeviceDtos.View> topDevices, List<AlertDtos.EventView> recentAlerts
    ) {}
}
