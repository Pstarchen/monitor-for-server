package com.guanlan.monitor.service;

import com.guanlan.monitor.domain.Device;
import com.guanlan.monitor.repository.DeviceRepository;
import com.guanlan.monitor.repository.MetricSnapshotRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.time.Duration;
import java.time.Instant;

@Component
@RequiredArgsConstructor
public class MaintenanceJobs {
    private final DeviceRepository devices;
    private final MetricSnapshotRepository metrics;
    private final SettingService settings;
    private final AlertService alerts;

    @Scheduled(fixedDelay = 10_000, initialDelay = 10_000)
    @Transactional
    public void detectOfflineDevices() {
        int offlineSeconds = settings.offlineSeconds();
        Instant cutoff = Instant.now().minusSeconds(offlineSeconds);
        Instant now = Instant.now();
        for (Device device : devices.findAll()) {
            if (device.getLastSeenAt() == null || device.getLastSeenAt().isAfter(cutoff)) continue;
            device.setStatus(Device.Status.OFFLINE);
            double elapsed = Duration.between(device.getLastSeenAt(), now).toSeconds();
            alerts.evaluateOffline(device, elapsed);
        }
    }

    @Scheduled(cron = "0 20 3 * * *")
    @Transactional
    public void removeExpiredMetrics() {
        metrics.deleteByCollectedAtBefore(Instant.now().minus(Duration.ofDays(settings.retentionDays())));
    }
}
