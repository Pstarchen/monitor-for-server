package com.guanlan.monitor.service;

import com.guanlan.monitor.domain.ServiceCheck;
import com.guanlan.monitor.domain.ServiceCheckResult;
import com.guanlan.monitor.repository.ServiceCheckRepository;
import com.guanlan.monitor.repository.ServiceCheckResultRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

class ServiceMonitorServiceTest {
    private final ServiceCheckRepository checks = mock(ServiceCheckRepository.class);
    private final ServiceCheckResultRepository results = mock(ServiceCheckResultRepository.class);
    private final ServiceProbe probe = mock(ServiceProbe.class);
    private final AuditService audit = mock(AuditService.class);
    private final NotificationService notifications = mock(NotificationService.class);
    private final SettingService settings = mock(SettingService.class);
    private final ServiceMonitorService service = new ServiceMonitorService(checks, results, probe, audit, notifications, settings);
    private ServiceCheck check;

    @BeforeEach
    void setUp() {
        check = new ServiceCheck();
        check.setId(42L);
        check.setName("官网健康检查");
        check.setTarget("https://example.com/health");
        check.setType(ServiceCheck.Type.HTTP_GET);
        check.setIntervalSeconds(60);
        check.setFailureThreshold(2);
        check.setCertificateThresholdDays(14);
        when(checks.findAllByOrderBySortOrderDescNameAsc()).thenReturn(List.of(check));
        when(checks.findByEnabledTrueOrderBySortOrderDescNameAsc()).thenReturn(List.of(check));
        when(results.findTopByServiceCheckIdOrderByCheckedAtDesc(42L)).thenReturn(Optional.empty());
        when(settings.publicBrand()).thenReturn(new SettingService.PublicBrandView("星辰云巡", "/favicon.svg"));
    }

    @Test
    void notifiesOnlyAfterConfiguredConsecutiveFailureThreshold() {
        when(probe.check(check)).thenReturn(new ServiceProbe.Result(false, 120, 503, "HTTP 503", null));

        service.runEnabledChecks();

        assertThat(check.getConsecutiveFailures()).isEqualTo(1);
        assertThat(check.isAlertActive()).isFalse();
        verify(notifications, never()).sendMessage(anyString());

        service.runEnabledChecks();

        assertThat(check.getConsecutiveFailures()).isEqualTo(2);
        assertThat(check.isAlertActive()).isTrue();
        verify(notifications).sendMessage(contains("服务“官网健康检查”异常"));
    }

    @Test
    void notifiesOnceWhenTheServiceRecovers() {
        check.setFailureThreshold(1);
        check.setConsecutiveFailures(1);
        check.setAlertActive(true);
        when(probe.check(check)).thenReturn(new ServiceProbe.Result(true, 45, 200, null, null));

        service.runEnabledChecks();

        assertThat(check.getConsecutiveFailures()).isZero();
        assertThat(check.isAlertActive()).isFalse();
        verify(notifications).sendMessage(contains("服务“官网健康检查”已恢复"));
    }

    @Test
    void includesRecentHistoryAndSevenDayAvailabilityInTheServiceView() {
        ServiceCheckResult result = new ServiceCheckResult();
        result.setCheckedAt(Instant.now().minusSeconds(10));
        result.setSuccess(true);
        result.setLatencyMs(91);
        result.setStatusCode(200);
        result.setServiceCheck(check);
        when(results.findTopByServiceCheckIdOrderByCheckedAtDesc(42L)).thenReturn(Optional.of(result));
        when(results.findTop60ByServiceCheckIdOrderByCheckedAtDesc(42L)).thenReturn(List.of(result));
        when(results.countByServiceCheckIdAndCheckedAtBetween(eq(42L), any(), any())).thenReturn(100L);
        when(results.countByServiceCheckIdAndSuccessTrueAndCheckedAtBetween(eq(42L), any(), any())).thenReturn(91L);

        var view = service.list().get(0);

        assertThat(view.availabilityPercent()).isEqualTo(91.0);
        assertThat(view.history()).hasSize(1);
        assertThat(view.history().get(0).latencyMs()).isEqualTo(91);
    }
}
