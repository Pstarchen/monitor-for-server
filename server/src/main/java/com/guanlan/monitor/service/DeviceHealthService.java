package com.guanlan.monitor.service;

import com.guanlan.monitor.api.dto.DeviceHealthDtos;
import com.guanlan.monitor.api.dto.MetricView;
import com.guanlan.monitor.domain.Device;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;

@Service
@RequiredArgsConstructor
public class DeviceHealthService {
    private final SettingService settings;

    public DeviceHealthDtos.View describe(Device device, MetricView latest) {
        Instant now = Instant.now();
        int offlineAfterSeconds = Math.max(5, settings.offlineSeconds());
        int dataStaleAfterSeconds = Math.max(offlineAfterSeconds, Math.max(1, settings.agentCollectionSeconds()) * 2);
        Long lastSeenAge = ageSeconds(device.getLastSeenAt(), now);
        Long dataAge = latest == null ? null : ageSeconds(latest.collectedAt(), now);
        Instant expectedBy = device.getLastSeenAt() == null
                ? null
                : device.getLastSeenAt().plusSeconds(offlineAfterSeconds);
        List<DeviceHealthDtos.Check> checks = new ArrayList<>();
        checks.add(connectionCheck(device, lastSeenAge, offlineAfterSeconds));
        checks.add(dataCheck(latest, dataAge, dataStaleAfterSeconds));

        if (device.getLastSeenAt() == null) {
            return new DeviceHealthDtos.View(
                    device.getStatus(), DeviceHealthDtos.State.PENDING, "NOT_CONNECTED",
                    "尚未收到 Agent 上报，请在目标服务器执行安装命令",
                    DeviceHealthDtos.Severity.INFO, null, null, offlineAfterSeconds,
                    latest == null ? null : latest.collectedAt(), dataAge, null, List.copyOf(checks));
        }
        if (lastSeenAge != null && lastSeenAge > offlineAfterSeconds) {
            return new DeviceHealthDtos.View(
                    device.getStatus(), DeviceHealthDtos.State.OFFLINE, "HEARTBEAT_TIMEOUT",
                    "最近一次 Agent 上报已超过失联阈值，请检查服务、网络和 Agent 日志",
                    DeviceHealthDtos.Severity.CRITICAL, device.getLastSeenAt(), lastSeenAge,
                    offlineAfterSeconds, latest == null ? null : latest.collectedAt(), dataAge,
                    expectedBy, List.copyOf(checks));
        }
        if (latest == null || (dataAge != null && dataAge > dataStaleAfterSeconds)) {
            return new DeviceHealthDtos.View(
                    device.getStatus(), DeviceHealthDtos.State.DEGRADED, "DATA_STALE",
                    "Agent 已连接，但最近没有可用的指标快照",
                    DeviceHealthDtos.Severity.WARNING, device.getLastSeenAt(), lastSeenAge,
                    offlineAfterSeconds, latest == null ? null : latest.collectedAt(), dataAge,
                    expectedBy, List.copyOf(checks));
        }
        return new DeviceHealthDtos.View(
                device.getStatus(), DeviceHealthDtos.State.HEALTHY, "HEALTHY", "Agent 正常上报",
                DeviceHealthDtos.Severity.INFO, device.getLastSeenAt(), lastSeenAge,
                offlineAfterSeconds, latest.collectedAt(), dataAge, expectedBy, List.copyOf(checks));
    }

    private DeviceHealthDtos.Check connectionCheck(Device device, Long age, int threshold) {
        if (device.getLastSeenAt() == null) {
            return new DeviceHealthDtos.Check("agent_connection", DeviceHealthDtos.CheckState.PENDING,
                    "Agent 连接", "等待首次上报");
        }
        if (age != null && age > threshold) {
            return new DeviceHealthDtos.Check("agent_connection", DeviceHealthDtos.CheckState.FAIL,
                    "Agent 连接", "最近上报已超时");
        }
        return new DeviceHealthDtos.Check("agent_connection", DeviceHealthDtos.CheckState.PASS,
                "Agent 连接", "最近上报在失联阈值内");
    }

    private DeviceHealthDtos.Check dataCheck(MetricView latest, Long age, int threshold) {
        if (latest == null) {
            return new DeviceHealthDtos.Check("metric_data", DeviceHealthDtos.CheckState.PENDING,
                    "指标数据", "尚无指标快照");
        }
        if (age != null && age > threshold) {
            return new DeviceHealthDtos.Check("metric_data", DeviceHealthDtos.CheckState.WARN,
                    "指标数据", "最新快照已过期");
        }
        return new DeviceHealthDtos.Check("metric_data", DeviceHealthDtos.CheckState.PASS,
                "指标数据", "最近快照可用");
    }

    private Long ageSeconds(Instant value, Instant now) {
        if (value == null) return null;
        return Math.max(0L, Duration.between(value, now).getSeconds());
    }
}
