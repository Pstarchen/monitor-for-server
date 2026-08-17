package com.guanlan.monitor.service;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.api.dto.AgentReportRequest;
import com.guanlan.monitor.api.dto.MetricView;
import com.guanlan.monitor.domain.Device;
import com.guanlan.monitor.domain.MetricSnapshot;
import com.guanlan.monitor.realtime.RealtimeWebSocketHandler;
import com.guanlan.monitor.repository.MetricSnapshotRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Map;

@Service
@RequiredArgsConstructor
public class MetricService {
    private final DeviceService devices;
    private final MetricSnapshotRepository metrics;
    private final ObjectMapper mapper;
    private final AlertService alerts;
    private final PresenceService presence;
    private final SettingService settings;
    private final RealtimeWebSocketHandler realtime;

    @Transactional
    public MetricView ingest(String deviceId, String agentKey, AgentReportRequest report) {
        if (report.collectedAt().isAfter(Instant.now().plus(Duration.ofMinutes(5)))) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "采集时间不能晚于服务器时间 5 分钟以上");
        }
        Device device = devices.authenticateAgent(deviceId, agentKey);
        device.setHostname(report.host().hostname());
        device.setOs(join(report.host().platform(), report.host().platformVersion()));
        device.setArchitecture(report.host().architecture());
        device.setHardwareJson(json(Map.of("host", report.host(), "cpu", report.cpu(), "memory", report.memory())));
        device.setStatus(Device.Status.ONLINE);
        device.setLastSeenAt(Instant.now());
        alerts.evaluateOffline(device, 0);

        List<AgentReportRequest.DiskStats> disks = report.disks() == null ? List.of() : report.disks();
        MetricSnapshot metric = new MetricSnapshot();
        metric.setDevice(device);
        metric.setCollectedAt(report.collectedAt());
        metric.setCpuUsage(clampPercent(report.cpu().usagePercent()));
        metric.setMemoryUsage(clampPercent(report.memory().usagePercent()));
        metric.setSwapUsage(clampPercent(report.memory().swapPercent()));
        metric.setLoad1(report.cpu().load1());
        metric.setLoad5(report.cpu().load5());
        metric.setLoad15(report.cpu().load15());
        metric.setDiskUsage(disks.stream().mapToDouble(AgentReportRequest.DiskStats::usagePercent).max().orElse(0));
        metric.setDiskReadBps(disks.stream().mapToDouble(AgentReportRequest.DiskStats::readBytesPerSec).max().orElse(0));
        metric.setDiskWriteBps(disks.stream().mapToDouble(AgentReportRequest.DiskStats::writeBytesPerSec).max().orElse(0));
        metric.setNetworkSentBps(Math.max(0, report.network().bytesSentPerSec()));
        metric.setNetworkRecvBps(Math.max(0, report.network().bytesRecvPerSec()));
        metric.setTcpConnections(Math.max(0, report.network().tcpConnections()));
        metric.setDisksJson(json(disks));
        metric.setProcessesJson(json(report.processes() == null ? List.of() : report.processes()));
        metric.setServicesJson(json(report.services() == null ? List.of() : report.services()));
        metrics.save(metric);

        MetricView view = MetricView.from(metric, mapper);
        alerts.evaluateMetric(device, metric);
        presence.markOnline(deviceId, view, settings.offlineSeconds());
        realtime.broadcast(Map.of("type", "metric.updated", "payload", view));
        return view;
    }

    @Transactional(readOnly = true)
    public MetricView latest(String deviceId) {
        devices.require(deviceId);
        return metrics.findTopByDeviceIdOrderByCollectedAtDesc(deviceId)
                .map(metric -> MetricView.from(metric, mapper))
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "暂无监控数据"));
    }

    @Transactional(readOnly = true)
    public List<MetricView> history(String deviceId, Instant from, Instant to) {
        devices.require(deviceId);
        if (from == null || to == null || from.isAfter(to) || Duration.between(from, to).toDays() > 31) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "历史查询时间范围无效或超过 31 天");
        }
        return metrics.findByDeviceIdAndCollectedAtBetweenOrderByCollectedAtAsc(deviceId, from, to).stream()
                .map(metric -> MetricView.from(metric, mapper)).toList();
    }

    private String json(Object value) {
        try { return mapper.writeValueAsString(value); }
        catch (JsonProcessingException exception) { throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "监控数据序列化失败"); }
    }

    private double clampPercent(double value) { return Math.min(100, Math.max(0, value)); }
    private String join(String first, String second) { return ((first == null ? "" : first) + " " + (second == null ? "" : second)).trim(); }
}
