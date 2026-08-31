package com.guanlan.monitor.service;

import com.guanlan.monitor.api.dto.MetricView;
import com.guanlan.monitor.domain.Device;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.Instant;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class DeviceHealthServiceTest {
    private final SettingService settings = mock(SettingService.class);
    private final DeviceHealthService service = new DeviceHealthService(settings);

    @BeforeEach
    void setUp() {
        when(settings.offlineSeconds()).thenReturn(30);
        when(settings.agentCollectionSeconds()).thenReturn(30);
    }

    @Test
    void explainsThatADeviceWithoutReportsIsWaitingForConnection() {
        Device device = new Device();
        device.setStatus(Device.Status.PENDING);

        var health = service.describe(device, null);

        assertThat(health.state()).isEqualTo(com.guanlan.monitor.api.dto.DeviceHealthDtos.State.PENDING);
        assertThat(health.reasonCode()).isEqualTo("NOT_CONNECTED");
        assertThat(health.lastSeenAgeSeconds()).isNull();
        assertThat(health.checks()).extracting("state").containsExactlyInAnyOrder(
                com.guanlan.monitor.api.dto.DeviceHealthDtos.CheckState.PENDING,
                com.guanlan.monitor.api.dto.DeviceHealthDtos.CheckState.PENDING);
    }

    @Test
    void marksReportsOlderThanTheOfflineThresholdAsOffline() {
        Device device = new Device();
        device.setStatus(Device.Status.ONLINE);
        device.setLastSeenAt(Instant.now().minusSeconds(45));

        var health = service.describe(device, null);

        assertThat(health.state()).isEqualTo(com.guanlan.monitor.api.dto.DeviceHealthDtos.State.OFFLINE);
        assertThat(health.reasonCode()).isEqualTo("HEARTBEAT_TIMEOUT");
        assertThat(health.lastSeenAgeSeconds()).isGreaterThanOrEqualTo(45);
        assertThat(health.checks()).extracting("state").contains(
                com.guanlan.monitor.api.dto.DeviceHealthDtos.CheckState.FAIL);
    }

    @Test
    void distinguishesHealthyAndStaleMetricData() {
        Device device = new Device();
        device.setStatus(Device.Status.ONLINE);
        device.setLastSeenAt(Instant.now().minusSeconds(3));
        MetricView latest = mock(MetricView.class);
        when(latest.collectedAt()).thenReturn(Instant.now().minusSeconds(45));

        var healthy = service.describe(device, latest);
        assertThat(healthy.state()).isEqualTo(com.guanlan.monitor.api.dto.DeviceHealthDtos.State.HEALTHY);

        when(latest.collectedAt()).thenReturn(Instant.now().minusSeconds(90));
        var stale = service.describe(device, latest);
        assertThat(stale.state()).isEqualTo(com.guanlan.monitor.api.dto.DeviceHealthDtos.State.DEGRADED);
        assertThat(stale.reasonCode()).isEqualTo("DATA_STALE");
    }
}
