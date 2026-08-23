package com.guanlan.monitor.service;

import com.guanlan.monitor.domain.Device;
import com.guanlan.monitor.repository.DeviceRepository;
import com.guanlan.monitor.repository.MetricSnapshotRepository;
import com.guanlan.monitor.repository.ServiceCheckResultRepository;
import com.guanlan.monitor.repository.AgentTaskRepository;
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
    private final ServiceMonitorService serviceMonitors;
    private final ServiceCheckResultRepository serviceResults;
    private final AgentTaskRepository agentTasks;
    private final AuditService audit;

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
        serviceResults.deleteByCheckedAtBefore(Instant.now().minus(Duration.ofDays(settings.retentionDays())));
    }

    @Scheduled(fixedDelay = 10_000, initialDelay = 15_000)
    public void probeServices() {
        serviceMonitors.runEnabledChecks();
    }

    @Scheduled(fixedDelay = 10_000, initialDelay = 20_000)
    @Transactional
    public void recoverStaleAgentTasks() {
        Instant now = Instant.now();
        for (var task : agentTasks.findByStatus(com.guanlan.monitor.domain.AgentTask.Status.RUNNING)) {
            if (task.getStartedAt() == null || task.getStartedAt().plusSeconds(task.getTimeoutSeconds() + taskTimeoutGraceSeconds()).isAfter(now)) continue;
            task.setStatus(com.guanlan.monitor.domain.AgentTask.Status.TIMED_OUT);
            task.setFinishedAt(now);
            task.setError("Agent 任务超时或连接中断");
            audit.record("AGENT_TASK_TIMEOUT", "task:" + task.getId(), "Agent 任务超时或连接中断");
        }
    }

    private long taskTimeoutGraceSeconds() {
        // Add a short grace period so a result arriving at the configured deadline is accepted.
        return 10;
    }
}
