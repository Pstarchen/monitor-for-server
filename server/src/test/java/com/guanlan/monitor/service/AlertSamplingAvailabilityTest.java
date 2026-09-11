package com.guanlan.monitor.service;

import com.guanlan.monitor.domain.AlertEvent;
import com.guanlan.monitor.domain.AlertRule;
import com.guanlan.monitor.domain.Device;
import com.guanlan.monitor.domain.MetricSnapshot;
import com.guanlan.monitor.realtime.RealtimeWebSocketHandler;
import com.guanlan.monitor.repository.AlertEventRepository;
import com.guanlan.monitor.repository.AlertRuleRepository;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Optional;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class AlertSamplingAvailabilityTest {
    @Test
    void unknownNetworkRateKeepsHighThroughputAlertOpenUntilAnActualZeroArrives() {
        assertUnknownDoesNotResolve(AlertRule.Metric.NETWORK_RECV_BPS, true);
        assertUnknownDoesNotResolve(AlertRule.Metric.NETWORK_SENT_BPS, true);
    }

    @Test
    void unknownDiskCounterKeepsHighThroughputAlertOpenUntilAnActualZeroArrives() {
        assertUnknownDoesNotResolve(AlertRule.Metric.DISK_READ_BPS, false);
        assertUnknownDoesNotResolve(AlertRule.Metric.DISK_WRITE_BPS, false);
    }

    private void assertUnknownDoesNotResolve(AlertRule.Metric kind, boolean network) {
        var rules = mock(AlertRuleRepository.class);
        var events = mock(AlertEventRepository.class);
        var realtime = mock(RealtimeWebSocketHandler.class);
        var service = new AlertService(rules, events, mock(DeviceService.class), mock(NotificationService.class), realtime, mock(AuditService.class));
        var device = new Device();
        device.setId("device-1");
        var rule = new AlertRule();
        rule.setId(1L);
        rule.setMetric(kind);
        rule.setThreshold(100);
        when(rules.findByEnabledTrue()).thenReturn(List.of(rule));
        var active = new AlertEvent();
        active.setStatus(AlertEvent.Status.OPEN);
        when(events.findFirstByDeviceIdAndRuleIdAndStatusInOrderByStartedAtDesc(eq("device-1"), eq(1L), any())).thenReturn(Optional.of(active));
        var snapshot = new MetricSnapshot();
        if (network) snapshot.setNetworkJson("{\"available\":true,\"ratesAvailable\":false}");
        else snapshot.setDisksJson("[{\"ioAvailable\":false,\"ioDevice\":\"block:253:0\"}]");

        service.evaluateMetric(device, snapshot);

        assertThat(active.getStatus()).isEqualTo(AlertEvent.Status.OPEN);
        assertThat(active.getResolvedAt()).isNull();
        verifyNoInteractions(events, realtime);
        if (!network) {
            snapshot.setDisksJson("[]");
            service.evaluateMetric(device, snapshot);
            assertThat(active.getStatus()).isEqualTo(AlertEvent.Status.OPEN);
            verifyNoInteractions(events, realtime);
            snapshot.setDisksJson("{}");
            service.evaluateMetric(device, snapshot);
            assertThat(active.getStatus()).isEqualTo(AlertEvent.Status.OPEN);
            verifyNoInteractions(events, realtime);
        }
        if (network) snapshot.setNetworkJson("{\"available\":true,\"ratesAvailable\":true}");
        else snapshot.setDisksJson("[{\"ioAvailable\":true,\"ioDevice\":\"block:253:0\"}]");

        service.evaluateMetric(device, snapshot);

        assertThat(active.getStatus()).isEqualTo(AlertEvent.Status.RESOLVED);
        assertThat(active.getResolvedAt()).isNotNull();
    }
}
