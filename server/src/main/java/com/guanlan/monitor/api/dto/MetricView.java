package com.guanlan.monitor.api.dto;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.domain.MetricSnapshot;

import java.time.Instant;
import java.util.List;

public record MetricView(
        Long id,
        String deviceId,
        Instant collectedAt,
        double cpuUsage,
        double memoryUsage,
        double swapUsage,
        double load1,
        double load5,
        double load15,
        double diskUsage,
        double diskReadBps,
        double diskWriteBps,
        double networkSentBps,
        double networkRecvBps,
        long networkSentBytes,
        long networkRecvBytes,
        int tcpConnections,
        double temperatureMax,
        Double gpuUsage,
        Double batteryPercent,
        Double containerCpuUsage,
        Double containerMemoryUsage,
        int smartPassed,
        int smartFailed,
        int smartUnknown,
        int integrityChanges,
        Integer firewallInactive,
        List<AgentReportRequest.NetworkInterface> networkInterfaces,
        List<AgentReportRequest.PortStats> ports,
        List<AgentReportRequest.ContainerStats> containers,
        List<AgentReportRequest.DiskStats> disks,
        List<AgentReportRequest.ProcessStats> processes,
        List<AgentReportRequest.ServiceStatus> services,
        List<AgentReportRequest.Fan> fans,
        List<AgentReportRequest.Battery> batteries,
        List<AgentReportRequest.Gpu> gpus,
        AgentReportRequest.FirewallStatus firewall,
        List<AgentReportRequest.CronJob> cronJobs,
        List<AgentReportRequest.LogFile> logs,
        List<AgentReportRequest.LogFile> systemLogs,
        List<AgentReportRequest.IntegrityItem> integrity,
        List<AgentReportRequest.CustomMetricResult> customMetrics
) {
    public static MetricView from(MetricSnapshot metric, ObjectMapper mapper) {
        return new MetricView(
                metric.getId(), metric.getDevice().getId(), metric.getCollectedAt(),
                metric.getCpuUsage(), metric.getMemoryUsage(), metric.getSwapUsage(),
                metric.getLoad1(), metric.getLoad5(), metric.getLoad15(), metric.getDiskUsage(),
                metric.getDiskReadBps(), metric.getDiskWriteBps(), metric.getNetworkSentBps(),
                metric.getNetworkRecvBps(), metric.getNetworkSentBytes(), metric.getNetworkRecvBytes(), metric.getTcpConnections(), metric.getTemperatureMax(),
                metric.getGpuUsage(), metric.getBatteryPercent(), metric.getContainerCpuUsage(), metric.getContainerMemoryUsage(),
                metric.getSmartPassed(), metric.getSmartFailed(), metric.getSmartUnknown(),
                metric.getIntegrityChanges(), metric.getFirewallInactive(),
                readList(mapper, metric.getNetworkInterfacesJson(), new TypeReference<>() {}),
                readList(mapper, metric.getPortsJson(), new TypeReference<>() {}),
                readList(mapper, metric.getContainersJson(), new TypeReference<>() {}),
                readList(mapper, metric.getDisksJson(), new TypeReference<>() {}),
                readList(mapper, metric.getProcessesJson(), new TypeReference<>() {}),
                readList(mapper, metric.getServicesJson(), new TypeReference<>() {}),
                readList(mapper, metric.getFansJson(), new TypeReference<>() {}),
                readList(mapper, metric.getBatteriesJson(), new TypeReference<>() {}),
                readList(mapper, metric.getGpusJson(), new TypeReference<>() {}),
                readObject(mapper, metric.getFirewallJson(), AgentReportRequest.FirewallStatus.class),
                readList(mapper, metric.getCronJobsJson(), new TypeReference<>() {}),
                readList(mapper, metric.getLogsJson(), new TypeReference<>() {}),
                readList(mapper, metric.getSystemLogsJson(), new TypeReference<>() {}),
                readList(mapper, metric.getIntegrityJson(), new TypeReference<>() {}),
                readList(mapper, metric.getCustomMetricsJson(), new TypeReference<>() {})
        );
    }

    private static <T> T readObject(ObjectMapper mapper, String json, Class<T> type) {
        if (json == null || json.isBlank()) return null;
        try { return mapper.readValue(json, type); }
        catch (Exception ignored) { return null; }
    }

    private static <T> List<T> readList(ObjectMapper mapper, String json, TypeReference<List<T>> type) {
        if (json == null || json.isBlank()) return List.of();
        try {
            return mapper.readValue(json, type);
        } catch (Exception ignored) {
            return List.of();
        }
    }
}
