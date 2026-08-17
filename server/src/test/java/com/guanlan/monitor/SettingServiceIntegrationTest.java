package com.guanlan.monitor;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.domain.SystemSetting;
import com.guanlan.monitor.repository.SystemSettingRepository;
import com.guanlan.monitor.service.NotificationService;
import com.guanlan.monitor.service.SettingService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.transaction.annotation.Transactional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

@SpringBootTest
@ActiveProfiles("test")
@Transactional
class SettingServiceIntegrationTest {
    private static final String EMAIL_PASSWORD = "notification.email.password";

    @Autowired SettingService settings;
    @Autowired NotificationService notifications;
    @Autowired SystemSettingRepository repository;

    @Test
    void notificationSecretsAreEncryptedAndNeverReturned() {
        SettingService.View view = settings.update(update(
                new SettingService.EmailUpdate(true, "smtp.example.com", 587, "monitor",
                        "database-only-password", false, "monitor@example.com", "ops@example.com", true, true),
                new SettingService.WebhookUpdate(false, null, false)
        ));

        String stored = repository.findById(EMAIL_PASSWORD).map(SystemSetting::getValue).orElseThrow();
        assertThat(stored).startsWith("v1:").doesNotContain("database-only-password");
        assertThat(view.email().passwordConfigured()).isTrue();
        assertThat(view.email().source()).isEqualTo("DATABASE");
        assertThat(view.toString()).doesNotContain("database-only-password");
    }

    @Test
    void invalidWebhookHostIsRejected() {
        assertThatThrownBy(() -> settings.update(update(
                disabledEmail(),
                new SettingService.WebhookUpdate(true, "https://example.com/webhook/token", false)
        ))).isInstanceOf(ApiException.class).hasMessageContaining("钉钉 Webhook 地址无效");
    }

    @Test
    void disabledChannelCannotReportSuccessfulTest() {
        settings.update(update(disabledEmail(), new SettingService.WebhookUpdate(false, null, false)));

        assertThatThrownBy(() -> notifications.test("email"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("请先启用");
    }

    private SettingService.Update update(SettingService.EmailUpdate email,
                                         SettingService.WebhookUpdate dingtalk) {
        return new SettingService.Update(30, 30, 3, "观澜监控", "http://localhost:8080", "Asia/Shanghai",
                email, dingtalk, new SettingService.WebhookUpdate(false, null, false));
    }

    private SettingService.EmailUpdate disabledEmail() {
        return new SettingService.EmailUpdate(false, "", 587, "", null, false, "", "", true, true);
    }
}
