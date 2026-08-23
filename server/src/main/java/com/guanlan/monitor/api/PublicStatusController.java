package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.DeviceDtos;
import com.guanlan.monitor.api.dto.ServiceDtos;
import com.guanlan.monitor.domain.Device;
import com.guanlan.monitor.service.DeviceService;
import com.guanlan.monitor.service.ServiceMonitorService;
import com.guanlan.monitor.service.SettingService;
import lombok.RequiredArgsConstructor;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.Instant;
import java.util.List;

@RestController
@RequestMapping("/api/public")
@RequiredArgsConstructor
public class PublicStatusController {
    private final DeviceService devices;
    private final ServiceMonitorService services;
    private final SettingService settings;

    @GetMapping("/overview")
    ResponseEntity<Overview> overview() {
        List<PublicDevice> publicDevices = devices.list().stream().filter(DeviceDtos.View::publicVisible).map(PublicDevice::from).toList();
        long online = publicDevices.stream().filter(device -> device.status() == Device.Status.ONLINE).count();
        long offline = publicDevices.stream().filter(device -> device.status() == Device.Status.OFFLINE).count();
        double sent = publicDevices.stream().mapToDouble(PublicDevice::networkSentBps).sum();
        double received = publicDevices.stream().mapToDouble(PublicDevice::networkRecvBps).sum();
        long totalSent = publicDevices.stream().mapToLong(PublicDevice::networkSentBytes).sum();
        long totalReceived = publicDevices.stream().mapToLong(PublicDevice::networkRecvBytes).sum();
        return ResponseEntity.ok()
                .cacheControl(CacheControl.noStore())
                .body(new Overview(settings.publicBrand().siteName(), Instant.now(), publicDevices.size(), online, offline, sent, received, totalSent, totalReceived, publicDevices, services.listPublic()));
    }

    public record Overview(String siteName, Instant generatedAt, int totalDevices, long onlineDevices, long offlineDevices, double networkSentBps, double networkRecvBps, long totalNetworkSentBytes, long totalNetworkRecvBytes, List<PublicDevice> devices, List<ServiceDtos.PublicView> services) {}

    public record PublicDevice(String id, String name, String groupName, String os, Device.Status status, Instant lastSeenAt, double cpuUsage, double memoryUsage, double diskUsage, double networkSentBps, double networkRecvBps, long networkSentBytes, long networkRecvBytes, long uptimeSeconds) {
        static PublicDevice from(DeviceDtos.View device) {
            var latest = device.latest();
            long uptime = 0;
            if (device.hardware() != null && device.hardware().get("host") instanceof java.util.Map<?, ?> host) {
                Object raw = host.get("uptimeSeconds");
                if (raw instanceof Number value) uptime = Math.max(0, value.longValue());
            }
            return new PublicDevice(device.id(), device.name(), device.groupName(), device.os(), device.status(), device.lastSeenAt(), latest == null ? 0 : latest.cpuUsage(), latest == null ? 0 : latest.memoryUsage(), latest == null ? 0 : latest.diskUsage(), latest == null ? 0 : latest.networkSentBps(), latest == null ? 0 : latest.networkRecvBps(), latest == null ? 0 : latest.networkSentBytes(), latest == null ? 0 : latest.networkRecvBytes(), uptime);
        }
    }
}
