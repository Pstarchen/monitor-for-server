package com.guanlan.monitor.service;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.domain.AlertEvent;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.mail.SimpleMailMessage;
import org.springframework.mail.javamail.JavaMailSenderImpl;
import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClient;
import org.springframework.http.client.SimpleClientHttpRequestFactory;

import java.util.Map;
import java.util.Properties;
import java.time.Duration;

@Service
public class NotificationService {
    private static final Logger log = LoggerFactory.getLogger(NotificationService.class);
    private final SettingService settings;
    private final AuditService audit;
    private final RestClient restClient;

    public NotificationService(SettingService settings, AuditService audit, RestClient.Builder builder) {
        this.settings = settings;
        this.audit = audit;
        this.restClient = builder.requestFactory(requestFactory()).build();
    }

    @Async
    public void send(AlertEvent event) {
        sendMessage("[" + brandName() + "] " + event.getMessage());
    }

    @Async
    public void sendMessage(String text) {
        SettingService.NotificationRuntime config = settings.notificationRuntime();
        runSafely("邮件", () -> sendEmail(config.email(), text));
        runSafely("钉钉", () -> sendWebhook(config.dingtalk(), text, "钉钉"));
        runSafely("企业微信", () -> sendWebhook(config.wecom(), text, "企业微信"));
    }

    public TestResult test(String channel) {
        SettingService.NotificationRuntime config = settings.notificationRuntime();
        String normalized = channel == null ? "" : channel.toLowerCase();
        String text = "[" + brandName() + "] 通知通道测试成功";
        try {
            switch (normalized) {
                case "email" -> {
                    requireEnabled(config.email().enabled());
                    sendEmail(config.email(), text);
                }
                case "dingtalk" -> {
                    requireEnabled(config.dingtalk().enabled());
                    sendWebhook(config.dingtalk(), text, "钉钉");
                }
                case "wecom" -> {
                    requireEnabled(config.wecom().enabled());
                    sendWebhook(config.wecom(), text, "企业微信");
                }
                default -> throw new ApiException(HttpStatus.NOT_FOUND, "通知通道不存在");
            }
        } catch (ApiException exception) {
            throw exception;
        } catch (Exception exception) {
            log.warn("Notification channel test failed: channel={}, error={}", normalized, exception.getClass().getSimpleName());
            throw new ApiException(HttpStatus.BAD_GATEWAY, "通知发送失败，请检查通道配置和网络连通性");
        }
        audit.record("NOTIFICATION_TEST", "channel:" + normalized, "测试通知通道");
        return new TestResult(normalized, "测试通知已发送");
    }

    private void sendEmail(SettingService.EmailRuntime config, String text) {
        if (!config.enabled()) return;
        if (blank(config.host()) || blank(config.from()) || blank(config.recipients())
                || (config.auth() && (blank(config.username()) || blank(config.password())))) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "邮件通知配置不完整");
        }
        JavaMailSenderImpl sender = new JavaMailSenderImpl();
        sender.setHost(config.host());
        sender.setPort(config.port());
        sender.setUsername(config.username());
        sender.setPassword(config.password());
        Properties javaMail = sender.getJavaMailProperties();
        javaMail.put("mail.smtp.auth", Boolean.toString(config.auth()));
        javaMail.put("mail.smtp.starttls.enable", Boolean.toString(config.startTls()));
        javaMail.put("mail.smtp.connectiontimeout", "10000");
        javaMail.put("mail.smtp.timeout", "10000");

        SimpleMailMessage message = new SimpleMailMessage();
        message.setFrom(config.from());
        message.setTo(config.recipients().split("\\s*,\\s*"));
        message.setSubject(brandName() + "通知测试与告警");
        message.setText(text);
        sender.send(message);
    }

    private void sendWebhook(SettingService.WebhookRuntime config, String text, String channel) {
        if (!config.enabled()) return;
        if (blank(config.url())) throw new ApiException(HttpStatus.BAD_REQUEST, "Webhook 通知配置不完整");
        WebhookResponse response = restClient.post().uri(config.url())
                .body(Map.of("msgtype", "text", "text", Map.of("content", text)))
                .retrieve().body(WebhookResponse.class);
        validateWebhookResponse(channel, response);
    }

    private void validateWebhookResponse(String channel, WebhookResponse response) {
        if (response == null || response.errcode() == null) {
            throw new ApiException(HttpStatus.BAD_GATEWAY, channel + "返回了无法识别的响应");
        }
        if (response.errcode() == 0) return;
        if ("钉钉".equals(channel) && response.errcode() == 90030) {
            throw new ApiException(HttpStatus.BAD_GATEWAY, "钉钉 Webhook 调用额度已用尽，请到钉钉开发者后台查看用量");
        }
        String detail = safeProviderMessage(response.errmsg());
        throw new ApiException(HttpStatus.BAD_GATEWAY,
                channel + "拒绝了消息（错误码 " + response.errcode() + "）" + (detail.isEmpty() ? "" : "：" + detail));
    }

    private String safeProviderMessage(String value) {
        if (blank(value)) return "";
        String normalized = value.replaceAll("[\\r\\n\\t]+", " ").trim();
        return normalized.length() > 160 ? normalized.substring(0, 160) : normalized;
    }

    private void runSafely(String channel, Runnable action) {
        try {
            action.run();
        } catch (ApiException exception) {
            log.warn("{} notification failed: {}", channel, exception.getMessage());
        } catch (Exception exception) {
            log.warn("{} notification failed: {}", channel, exception.getClass().getSimpleName());
        }
    }

    private void requireEnabled(boolean enabled) {
        if (!enabled) throw new ApiException(HttpStatus.BAD_REQUEST, "请先启用该通知通道");
    }

    private String brandName() {
        String value = settings.publicBrand().siteName();
        return value == null || value.isBlank() ? "星辰云巡" : value.trim();
    }

    private boolean blank(String value) { return value == null || value.isBlank(); }

    private static SimpleClientHttpRequestFactory requestFactory() {
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout(Duration.ofSeconds(5));
        factory.setReadTimeout(Duration.ofSeconds(10));
        return factory;
    }

    public record TestResult(String channel, String message) {}
    private record WebhookResponse(Integer errcode, String errmsg) {}
}
