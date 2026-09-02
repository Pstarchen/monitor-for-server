package com.guanlan.monitor.service;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.api.dto.AgentReportRequest;
import com.guanlan.monitor.api.dto.DeviceDtos;
import com.guanlan.monitor.api.dto.MetricView;
import com.guanlan.monitor.domain.Device;
import com.guanlan.monitor.repository.MetricSnapshotRepository;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentMatchers;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class MobileDiagnosticsServiceTest {
    private final DeviceService devices = mock(DeviceService.class);
    private final MetricService metrics = mock(MetricService.class);
    private final MobileDiagnosticsService service = new MobileDiagnosticsService(devices, metrics);

    @Test
    void buildsDiagnosticsAndIgnoresNullItemsFromStoredMetrics() {
        DeviceDtos.View device = mock(DeviceDtos.View.class);
        MetricView metric = mock(MetricView.class);
        when(device.status()).thenReturn(Device.Status.ONLINE);
        when(devices.get("device-1")).thenReturn(device);
        when(metrics.latest("device-1")).thenReturn(metric);
        when(metric.collectedAt()).thenReturn(Instant.parse("2026-09-01T00:00:00Z"));
        when(metric.networkInterfaces()).thenReturn(listWithNull(new AgentReportRequest.NetworkInterface(
                "eth0", 1500, "", listWithNull("UP"), listWithNull("10.0.0.1/24"))));
        when(metric.disks()).thenReturn(listWithNull(new AgentReportRequest.DiskStats(
                "/dev/sda", "/", "ext4", 100, 80, 20, 80,
                10, 20, new AgentReportRequest.SmartHealth("failed", "", 50, 100,
                2, 1, 0))));
        when(metric.processes()).thenReturn(listWithNull(
                new AgentReportRequest.ProcessStats(1, "low", "", "root", 10, 20, "RUNNING"),
                new AgentReportRequest.ProcessStats(2, "high", "", "root", 90, 70, "RUNNING")));
        when(metric.integrityChanges()).thenReturn(1);
        when(metric.firewall()).thenReturn(new AgentReportRequest.FirewallStatus("nftables", "inactive", ""));

        var result = service.diagnostics("device-1");

        assertThat(result.online()).isTrue();
        assertThat(result.networkInterfaces()).singleElement().satisfies(item -> {
            assertThat(item.flags()).containsExactly("UP");
            assertThat(item.addresses()).containsExactly("10.0.0.1/24");
        });
        assertThat(result.disks()).singleElement().satisfies(disk -> {
            assertThat(disk.smart().available()).isTrue();
            assertThat(disk.smart().status()).isEqualTo("FAILED");
        });
        assertThat(result.topCpuProcesses()).extracting("name").containsExactly("high", "low");
        assertThat(result.health().smartFailure()).isTrue();
        assertThat(result.health().integrityChanged()).isTrue();
        assertThat(result.health().firewallEnabled()).isFalse();
        assertThat(result.health().messages()).hasSize(3);
    }

    @Test
    void normalizesHistoryRangeAndUsesItsSamplingStep() {
        when(metrics.compactHistory(ArgumentMatchers.eq("device-1"), ArgumentMatchers.any(), ArgumentMatchers.any()))
                .thenReturn(List.of());

        var result = service.history("device-1", " 6h ");

        assertThat(result.range()).isEqualTo("6H");
        assertThat(result.sampleStepSeconds()).isEqualTo(300);
        assertThat(result.points()).isEmpty();
        assertThat(result.to().getEpochSecond() - result.from().getEpochSecond()).isEqualTo(6 * 60 * 60);
    }

    @Test
    void capsThirtyDayHistoryAtSevenHundredTwentyPoints() {
        when(metrics.compactHistory(ArgumentMatchers.eq("device-1"), ArgumentMatchers.any(), ArgumentMatchers.any()))
                .thenAnswer(invocation -> {
                    Instant from = invocation.getArgument(1);
                    List<MetricSnapshotRepository.HistorySample> result = new ArrayList<>();
                    for (int index = 0; index <= 30 * 48; index++) {
                        result.add(new HistorySample(from.plusSeconds(index * 30L * 60)));
                    }
                    return result;
                });

        var result = service.history("device-1", "30D");

        assertThat(result.sampleStepSeconds()).isEqualTo(3_600);
        assertThat(result.points()).hasSize(720);
        assertThat(result.points()).extracting("collectedAt").isSorted();
        assertThat(result.points().getLast().collectedAt()).isEqualTo(result.to());
    }

    @Test
    void rejectsUnsupportedHistoryRangeBeforeLoadingMetrics() {
        assertThatThrownBy(() -> service.history("device-1", "2H"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("1H");
        verify(metrics, never()).compactHistory(ArgumentMatchers.anyString(), ArgumentMatchers.any(), ArgumentMatchers.any());
    }

    private record HistorySample(Instant getCollectedAt) implements MetricSnapshotRepository.HistorySample {
        @Override public double getCpuUsage() { return 42; }
        @Override public double getMemoryUsage() { return 38; }
        @Override public double getSwapUsage() { return 0; }
        @Override public double getLoad1() { return 1; }
        @Override public double getLoad5() { return 1; }
        @Override public double getLoad15() { return 1; }
        @Override public double getTemperatureMax() { return 40; }
        @Override public double getDiskUsage() { return 55; }
        @Override public double getNetworkSentBps() { return 10; }
        @Override public double getNetworkRecvBps() { return 20; }
    }

    @SafeVarargs
    private static <T> List<T> listWithNull(T... values) {
        List<T> result = new ArrayList<>();
        result.add(null);
        result.addAll(List.of(values));
        return result;
    }
}
