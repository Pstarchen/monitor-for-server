package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.AgentReportRequest;
import com.guanlan.monitor.api.dto.DeviceDtos;
import com.guanlan.monitor.api.dto.DeviceHealthDtos;
import com.guanlan.monitor.api.dto.MetricView;
import com.guanlan.monitor.domain.Device;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class DashboardMetricsTest {
    @Test
    void onlineHeartbeatWithStaleMetricsDoesNotContributeToRealtimeTotals() {
        var device = device(DeviceHealthDtos.State.DEGRADED);
        assertThat(DashboardController.hasCurrentMetrics(device)).isFalse();
        assertThat(PublicStatusController.PublicDevice.from(device).networkRecvBps()).isZero();
    }

    @Test
    void legacyReportsStayUsableButExplicitUnavailableRatesAreExcluded() {
        var device = device(DeviceHealthDtos.State.HEALTHY);
        assertThat(DashboardController.hasCurrentNetworkRates(device)).isTrue();
        assertThat(PublicStatusController.PublicDevice.from(device).networkRecvBps()).isEqualTo(800);
        when(device.latest().network()).thenReturn(new AgentReportRequest.NetworkStats(0, 0, 100, 200, 0, java.util.List.of("eth0"), true, false));
        assertThat(DashboardController.hasCurrentMetrics(device)).isTrue();
        assertThat(DashboardController.hasCurrentNetworkRates(device)).isFalse();
        assertThat(PublicStatusController.PublicDevice.from(device).networkRecvBps()).isZero();
        assertThat(PublicStatusController.PublicDevice.from(device).networkRecvBytes()).isEqualTo(200);
    }

    private DeviceDtos.View device(DeviceHealthDtos.State state) {
        var device = mock(DeviceDtos.View.class);
        var metric = mock(MetricView.class);
        var health = mock(DeviceHealthDtos.View.class);
        when(device.status()).thenReturn(Device.Status.ONLINE);
        when(device.latest()).thenReturn(metric);
        when(device.health()).thenReturn(health);
        when(health.state()).thenReturn(state);
        when(metric.networkRecvBps()).thenReturn(800d);
        when(metric.networkRecvBytes()).thenReturn(200L);
        return device;
    }
}
