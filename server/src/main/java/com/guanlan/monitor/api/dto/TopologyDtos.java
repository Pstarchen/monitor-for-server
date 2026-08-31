package com.guanlan.monitor.api.dto;

import com.guanlan.monitor.domain.ServiceCheck;

import java.util.List;

public final class TopologyDtos {
    private TopologyDtos() {}

    public record View(List<Node> nodes, List<Edge> edges, int monitoredServices, int unresolvedServices) {}

    public record Node(
            String id,
            String label,
            String kind,
            String status,
            String hostname,
            String address,
            Double cpuUsage,
            Double memoryUsage,
            Double diskUsage,
            int serviceCount
    ) {}

    public record Edge(
            String id,
            String source,
            String target,
            String label,
            ServiceCheck.Type type,
            String status,
            Long latencyMs,
            String targetHost
    ) {}
}
