package com.guanlan.monitor.api.dto;

import com.guanlan.monitor.domain.DiscoveryScan;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.Size;

import java.time.Instant;
import java.util.List;

public final class DiscoveryDtos {
    private DiscoveryDtos() {}

    public record StartRequest(
            @Size(max = 43) String cidr,
            @Size(max = 32) List<Integer> ports,
            @Min(50) @Max(3000) Integer timeoutMs,
            @Min(1) @Max(32) Integer concurrency
    ) {}

    public record View(
            Long id, String cidr, List<Integer> ports, int timeoutMs, int concurrency,
            DiscoveryScan.Status status, int totalHosts, int scannedHosts, int discoveredHosts,
            String createdBy, Instant createdAt, Instant startedAt, Instant finishedAt, String error
    ) {}

    public record ResultView(
            Long id, String address, String hostname, boolean reachable, List<Integer> openPorts,
            Integer latencyMs, Instant discoveredAt
    ) {}

    public record Detail(View scan, List<ResultView> results) {}
}
