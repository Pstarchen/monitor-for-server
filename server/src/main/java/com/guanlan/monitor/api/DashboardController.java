package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.AlertDtos;
import com.guanlan.monitor.api.dto.DeviceDtos;
import com.guanlan.monitor.domain.AlertEvent;
import com.guanlan.monitor.domain.Device;
import com.guanlan.monitor.repository.AlertEventRepository;
import com.guanlan.monitor.repository.DeviceRepository;
import com.guanlan.monitor.service.AlertService;
import com.guanlan.monitor.service.DeviceService;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Comparator;
import java.util.List;

@RestController
@RequestMapping("/api/dashboard")
@RequiredArgsConstructor
public class DashboardController {
    private final DeviceRepository deviceRepository;
    private final AlertEventRepository alertRepository;
    private final DeviceService deviceService;
    private final AlertService alertService;

    @GetMapping
    DashboardView get() {
        List<DeviceDtos.View> devices = deviceService.list();
        List<DeviceDtos.View> measured = devices.stream()
                .filter(device -> device.status() == Device.Status.ONLINE && device.latest() != null).toList();
        List<DeviceDtos.View> top = measured.stream()
                .sorted(Comparator.comparingDouble((DeviceDtos.View device) -> device.latest().cpuUsage()).reversed())
                .limit(5).toList();
        return new DashboardView(
                deviceRepository.count(),
                deviceRepository.countByStatus(Device.Status.ONLINE),
                deviceRepository.countByStatus(Device.Status.OFFLINE),
                deviceRepository.countByStatus(Device.Status.PENDING),
                alertRepository.countByStatusIn(List.of(AlertEvent.Status.OPEN, AlertEvent.Status.ACKNOWLEDGED)),
                average(measured, "cpu"), average(measured, "memory"), average(measured, "disk"),
                measured.stream().mapToDouble(device -> device.latest().networkSentBps()).sum(),
                measured.stream().mapToDouble(device -> device.latest().networkRecvBps()).sum(),
                devices, top, alertService.listEvents(6)
        );
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
