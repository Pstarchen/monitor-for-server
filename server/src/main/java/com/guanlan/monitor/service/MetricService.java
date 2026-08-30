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
        List<AgentReportRequest.ContainerStats> containers = report.containers() == null ? List.of() : report.containers();
        List<AgentReportRequest.Fan> fans = report.host().fans() == null ? List.of() : report.host().fans();
        List<AgentReportRequest.Battery> batteries = report.host().batteries() == null ? List.of() : report.host().batteries();
        List<AgentReportRequest.Gpu> gpus = report.host().gpus() == null ? List.of() : report.host().gpus();
        MetricSnapshot metric = new MetricSnapshot();
        metric.setDevice(device);
        metric.setCollectedAt(report.collectedAt());
        metric.setCpuUsage(clampPercent(report.cpu().usagePercent()));
        metric.setMemoryUsage(clampPercent(report.memory().usagePercent()));
        metric.setSwapUsage(clampPercent(report.memory().swapPercent()));
        metric.setLoad1(nonNegativeFinite(report.cpu().load1()));
        metric.setLoad5(nonNegativeFinite(report.cpu().load5()));
        metric.setLoad15(nonNegativeFinite(report.cpu().load15()));
        metric.setDiskUsage(disks.stream().mapToDouble(disk -> clampPercent(disk.usagePercent())).max().orElse(0));
        metric.setDiskReadBps(disks.stream().mapToDouble(disk -> nonNegativeFinite(disk.readBytesPerSec())).max().orElse(0));
        metric.setDiskWriteBps(disks.stream().mapToDouble(disk -> nonNegativeFinite(disk.writeBytesPerSec())).max().orElse(0));
        metric.setNetworkSentBps(nonNegativeFinite(report.network().bytesSentPerSec()));
        metric.setNetworkRecvBps(nonNegativeFinite(report.network().bytesRecvPerSec()));
        metric.setNetworkSentBytes(Math.max(0, report.network().bytesSent()));
        metric.setNetworkRecvBytes(Math.max(0, report.network().bytesRecv()));
        metric.setTcpConnections(Math.max(0, report.network().tcpConnections()));
        metric.setTemperatureMax(report.host().temperatures() == null ? 0 : report.host().temperatures().stream()
                .mapToDouble(temperature -> Double.isFinite(temperature.value()) ? Math.max(0, temperature.value()) : 0)
                .max().orElse(0));
        metric.setGpuUsage(maxOptional(gpus.stream().mapToDouble(gpu -> clampPercent(gpu.usagePercent())).boxed().toList()));
        metric.setBatteryPercent(minOptional(batteries.stream().mapToDouble(battery -> clampPercent(battery.percent())).boxed().toList()));
        metric.setContainerCpuUsage(maxOptional(containers.stream().mapToDouble(container -> nonNegativeFinite(container.cpuPercent())).boxed().toList()));
        metric.setContainerMemoryUsage(maxOptional(containers.stream().mapToDouble(container -> clampPercent(container.memoryPercent())).boxed().toList()));
        metric.setSmartPassed(smartCount(disks, "PASSED"));
        metric.setSmartFailed(smartCount(disks, "FAILED"));
        metric.setSmartUnknown(smartCount(disks, "UNKNOWN"));
        metric.setDisksJson(json(disks));
        metric.setProcessesJson(json(report.processes() == null ? List.of() : report.processes()));
        metric.setServicesJson(json(report.services() == null ? List.of() : report.services()));
        metric.setNetworkInterfacesJson(json(report.networkInterfaces() == null ? List.of() : report.networkInterfaces()));
        metric.setPortsJson(json(report.ports() == null ? List.of() : report.ports()));
        metric.setContainersJson(json(containers));
        metric.setFansJson(json(fans));
        metric.setBatteriesJson(json(batteries));
        metric.setGpusJson(json(gpus));
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

    private double clampPercent(double value) { return Double.isFinite(value) ? Math.min(100, Math.max(0, value)) : 0; }
    private double nonNegativeFinite(double value) { return Double.isFinite(value) ? Math.max(0, value) : 0; }

    private Double maxOptional(List<Double> values) {
        return values.stream().filter(value -> value != null && Double.isFinite(value)).max(Double::compareTo).orElse(null);
    }

    private Double minOptional(List<Double> values) {
        return values.stream().filter(value -> value != null && Double.isFinite(value)).min(Double::compareTo).orElse(null);
    }

    private int smartCount(List<AgentReportRequest.DiskStats> disks, String status) {
        return (int) disks.stream()
                .filter(disk -> disk != null && disk.smart() != null)
                .filter(disk -> status.equalsIgnoreCase(disk.smart().status()))
                .count();
    }
    private String join(String first, String second) { return ((first == null ? "" : first) + " " + (second == null ? "" : second)).trim(); }
}
