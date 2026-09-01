package com.guanlan.monitor;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.domain.SystemSetting;
import com.guanlan.monitor.repository.SystemSettingRepository;
import com.guanlan.monitor.service.NotificationService;
import com.guanlan.monitor.service.PushKitConfigurationService;
import com.guanlan.monitor.service.SettingService;
import com.guanlan.monitor.push.PushKitClient;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.transaction.annotation.Transactional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.security.KeyPairGenerator;
import java.util.Base64;

@SpringBootTest
@ActiveProfiles("test")
@Transactional
class SettingServiceIntegrationTest {
    private static final String EMAIL_PASSWORD = "notification.email.password";

    @Autowired SettingService settings;
    @Autowired NotificationService notifications;
    @Autowired SystemSettingRepository repository;
    @Autowired PushKitConfigurationService pushKitConfigurations;
    @Autowired PushKitClient pushKitClient;

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
        assertThat(view.siteIconUrl()).isEqualTo("/custom-icon.svg");
        assertThat(view.toString()).doesNotContain("database-only-password");
    }

    @Test
    void unsafeSiteIconUrlIsRejected() {
        assertThatThrownBy(() -> settings.update(new SettingService.Update(
                30, 30, 3, "星辰监控", "javascript:alert(1)", "http://localhost:8080", "Asia/Shanghai",
                disabledEmail(), new SettingService.WebhookUpdate(false, null, false),
                new SettingService.WebhookUpdate(false, null, false)
        ))).isInstanceOf(ApiException.class).hasMessageContaining("网站图标");
    }

    @Test
    void invalidWebhookHostIsRejected() {
        assertThatThrownBy(() -> settings.update(update(
                disabledEmail(),
                new SettingService.WebhookUpdate(true, "https://example.com/webhook/token", false)
        ))).isInstanceOf(ApiException.class).hasMessageContaining("钉钉 Webhook 地址无效");
    }

    @Test
    void publicBaseUrlMustBeAnOriginWithoutAPath() {
        assertThatThrownBy(() -> settings.update(new SettingService.Update(
                30, 30, 3, "星辰监控", "/brand-icon.png", "https://monitor.example.com/status", "Asia/Shanghai",
                disabledEmail(), new SettingService.WebhookUpdate(false, null, false), new SettingService.WebhookUpdate(false, null, false)
        ))).isInstanceOf(ApiException.class).hasMessageContaining("公网入口");
    }

    @Test
    void missingTimezoneReturnsBadRequestInsteadOfServerError() {
        assertThatThrownBy(() -> settings.update(new SettingService.Update(
                30, 30, 3, "星辰监控", "/brand-icon.png", "http://localhost:8080", null,
                disabledEmail(), new SettingService.WebhookUpdate(false, null, false), new SettingService.WebhookUpdate(false, null, false)
        ))).isInstanceOf(ApiException.class).hasMessageContaining("时区");
    }

    @Test
    void disabledChannelCannotReportSuccessfulTest() {
        settings.update(update(disabledEmail(), new SettingService.WebhookUpdate(false, null, false)));

        assertThatThrownBy(() -> notifications.test("email"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("请先启用");
    }

    @Test
    void mcpCanBeEnabledFromPersistedSettings() {
        SettingService.Update update = new SettingService.Update(30, 30, 3, "星辰监控", "/brand-icon.png", "http://localhost:8080", "Asia/Shanghai", true,
                disabledEmail(), new SettingService.WebhookUpdate(false, null, false), new SettingService.WebhookUpdate(false, null, false));
        assertThat(settings.update(update).enableMcp()).isTrue();
        assertThat(settings.mcpEnabled()).isTrue();
    }

    @Test
    void pushKitPrivateKeyIsEncryptedNotReturnedAndAppliedImmediately() throws Exception {
        var generator = KeyPairGenerator.getInstance("RSA");
        generator.initialize(2048);
        String encoded = Base64.getMimeEncoder(64, new byte[]{'\n'})
                .encodeToString(generator.generateKeyPair().getPrivate().getEncoded());
        String privateKey = "-----BEGIN PRIVATE KEY-----\n" + encoded + "\n-----END PRIVATE KEY-----";

        PushKitConfigurationService.View view = pushKitConfigurations.update(
                new PushKitConfigurationService.Update(true, "123456789", "key-id", "sub-account",
                        privateKey, false, "MARKETING", 86400, 50, 5));

        String stored = repository.findById("notification.push_kit.private_key")
                .map(SystemSetting::getValue).orElseThrow();
        assertThat(stored).startsWith("v1:").hasSizeGreaterThan(500).doesNotContain("BEGIN PRIVATE KEY");
        assertThat(view.privateKeyConfigured()).isTrue();
        assertThat(view.toString()).doesNotContain(privateKey).doesNotContain(encoded);
        assertThat(pushKitClient.enabled()).isTrue();
    }

    @Test
    void pushKitCannotBeEnabledWithoutACompleteServiceAccount() {
        assertThatThrownBy(() -> pushKitConfigurations.update(
                new PushKitConfigurationService.Update(true, "", "", "", null,
                        false, "MARKETING", 86400, 50, 5)))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("项目 ID");
    }

    private SettingService.Update update(SettingService.EmailUpdate email,
                                         SettingService.WebhookUpdate dingtalk) {
        return new SettingService.Update(30, 30, 3, "星辰监控", "/custom-icon.svg", "http://localhost:8080", "Asia/Shanghai",
                email, dingtalk, new SettingService.WebhookUpdate(false, null, false));
    }

    private SettingService.EmailUpdate disabledEmail() {
        return new SettingService.EmailUpdate(false, "", 587, "", null, false, "", "", true, true);
    }
}
