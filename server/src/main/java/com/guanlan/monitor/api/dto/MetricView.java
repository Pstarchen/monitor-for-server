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
        int tcpConnections,
        List<AgentReportRequest.DiskStats> disks,
        List<AgentReportRequest.ProcessStats> processes,
        List<AgentReportRequest.ServiceStatus> services
) {
    public static MetricView from(MetricSnapshot metric, ObjectMapper mapper) {
        return new MetricView(
                metric.getId(), metric.getDevice().getId(), metric.getCollectedAt(),
                metric.getCpuUsage(), metric.getMemoryUsage(), metric.getSwapUsage(),
                metric.getLoad1(), metric.getLoad5(), metric.getLoad15(), metric.getDiskUsage(),
                metric.getDiskReadBps(), metric.getDiskWriteBps(), metric.getNetworkSentBps(),
                metric.getNetworkRecvBps(), metric.getTcpConnections(),
                readList(mapper, metric.getDisksJson(), new TypeReference<>() {}),
                readList(mapper, metric.getProcessesJson(), new TypeReference<>() {}),
                readList(mapper, metric.getServicesJson(), new TypeReference<>() {})
        );
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

