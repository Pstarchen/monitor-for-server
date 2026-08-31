package com.guanlan.monitor.service;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.domain.AlertEvent;
import com.guanlan.monitor.domain.NotificationDelivery;
import com.guanlan.monitor.repository.NotificationDeliveryRepository;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.data.domain.PageRequest;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.mail.SimpleMailMessage;
import org.springframework.mail.javamail.JavaMailSenderImpl;
import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClient;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.web.util.UriComponentsBuilder;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.Properties;
import java.time.Duration;
import java.util.Base64;

@Service
public class NotificationService {
    private static final Logger log = LoggerFactory.getLogger(NotificationService.class);
    private final SettingService settings;
    private final AuditService audit;
    private final RestClient restClient;
    private final NotificationDeliveryRepository deliveries;

    /** Kept for isolated unit tests that do not start a JPA context. */
    public NotificationService(SettingService settings, AuditService audit, RestClient.Builder builder) {
        this(settings, audit, builder, null);
    }

    @Autowired
    public NotificationService(SettingService settings, AuditService audit, RestClient.Builder builder,
                               NotificationDeliveryRepository deliveries) {
        this.settings = settings;
        this.audit = audit;
        this.restClient = builder.requestFactory(requestFactory()).build();
        this.deliveries = deliveries;
    }

    @Async
    public void send(AlertEvent event) {
        sendMessage("[" + brandName() + "] " + event.getMessage());
    }

    @Async
    public void sendMessage(String text) {
        SettingService.NotificationRuntime config = settings.notificationRuntime();
        deliver("email", "邮件", text, config.email().enabled(), () -> sendEmail(config.email(), text));
        deliver("dingtalk", "钉钉", text, config.dingtalk().enabled(), () -> sendWebhook(config.dingtalk(), text, "钉钉"));
        deliver("wecom", "企业微信", text, config.wecom().enabled(), () -> sendWebhook(config.wecom(), text, "企业微信"));
        deliver("generic", "通用 Webhook", text, config.generic().enabled(), () -> sendGenericWebhook(config.generic(), text));
    }

    public TestResult test(String channel) {
        SettingService.NotificationRuntime config = settings.notificationRuntime();
        String normalized = channel == null ? "" : channel.toLowerCase();
        String text = "[" + brandName() + "] 通知通道测试成功";
        try {
            switch (normalized) {
                case "email" -> {
                    requireEnabled(config.email().enabled());
                    deliverSync("email", "邮件", text, () -> sendEmail(config.email(), text));
                }
                case "dingtalk" -> {
                    requireEnabled(config.dingtalk().enabled());
                    deliverSync("dingtalk", "钉钉", text, () -> sendWebhook(config.dingtalk(), text, "钉钉"));
                }
                case "wecom" -> {
                    requireEnabled(config.wecom().enabled());
                    deliverSync("wecom", "企业微信", text, () -> sendWebhook(config.wecom(), text, "企业微信"));
                }
                case "generic" -> {
                    requireEnabled(config.generic().enabled());
                    deliverSync("generic", "通用 Webhook", text, () -> sendGenericWebhook(config.generic(), text));
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

    public java.util.List<NotificationDeliveryView> listDeliveries(int limit) {
        if (deliveries == null) return java.util.List.of();
        return deliveries.findAllByOrderByCreatedAtDesc(PageRequest.of(0, Math.min(Math.max(limit, 1), 200))).stream()
                .map(item -> new NotificationDeliveryView(item.getId(), item.getChannel(), item.getStatus().name(), item.getMessage(), item.getError(), item.getAttempts(), item.getCreatedAt(), item.getFinishedAt()))
                .toList();
    }

    public NotificationDeliveryView retry(long id) {
        if (deliveries == null) throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "通知投递记录不可用");
        NotificationDelivery delivery = deliveries.findById(id)
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "通知投递记录不存在"));
        SettingService.NotificationRuntime config = settings.notificationRuntime();
        String channel = delivery.getChannel();
        Runnable action = switch (channel) {
            case "email" -> {
                requireEnabled(config.email().enabled());
                yield () -> sendEmail(config.email(), delivery.getMessage());
            }
            case "dingtalk" -> {
                requireEnabled(config.dingtalk().enabled());
                yield () -> sendWebhook(config.dingtalk(), delivery.getMessage(), "钉钉");
            }
            case "wecom" -> {
                requireEnabled(config.wecom().enabled());
                yield () -> sendWebhook(config.wecom(), delivery.getMessage(), "企业微信");
            }
            case "generic" -> {
                requireEnabled(config.generic().enabled());
                yield () -> sendGenericWebhook(config.generic(), delivery.getMessage());
            }
            default -> throw new ApiException(HttpStatus.BAD_REQUEST, "通知通道不存在");
        };
        deliverSync(delivery, channel, channel, action);
        audit.record("NOTIFICATION_RETRY", "delivery:" + id, "重试通知投递");
        return new NotificationDeliveryView(delivery.getId(), delivery.getChannel(), delivery.getStatus().name(), delivery.getMessage(), delivery.getError(), delivery.getAttempts(), delivery.getCreatedAt(), delivery.getFinishedAt());
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
        String content = text;
        URI endpoint = URI.create(config.url());
        if ("钉钉".equals(channel)) {
            if (!blank(config.keyword()) && !content.contains(config.keyword())) {
                content = content + "\n关键词: " + config.keyword().trim();
            }
            endpoint = dingtalkEndpoint(endpoint, config.signSecret());
        }
        WebhookResponse response = restClient.post().uri(endpoint)
                .contentType(MediaType.APPLICATION_JSON)
                .body(Map.of("msgtype", "text", "text", Map.of("content", content)))
                .retrieve().body(WebhookResponse.class);
        validateWebhookResponse(channel, response);
    }

    private void sendGenericWebhook(SettingService.WebhookRuntime config, String text) {
        if (!config.enabled()) return;
        if (blank(config.url())) throw new ApiException(HttpStatus.BAD_REQUEST, "通用 Webhook 配置不完整");
        URI endpoint = URI.create(config.url());
        String format = blank(config.payloadFormat()) ? "GENERIC_JSON" : config.payloadFormat().trim().toUpperCase(java.util.Locale.ROOT);
        if ("PLAIN_TEXT".equals(format)) {
            restClient.post().uri(endpoint)
                    .contentType(MediaType.parseMediaType("text/plain;charset=UTF-8"))
                    .body(text)
                    .retrieve().toBodilessEntity();
            return;
        }
        Object payload = switch (format) {
            case "SLACK" -> Map.of("text", text);
            case "DISCORD" -> Map.of("content", text);
            case "LARK" -> Map.of("msg_type", "text", "content", Map.of("text", text));
            case "GENERIC_JSON" -> Map.of("text", text);
            default -> throw new ApiException(HttpStatus.BAD_REQUEST, "通用 Webhook 消息格式无效");
        };
        restClient.post().uri(endpoint)
                .contentType(MediaType.APPLICATION_JSON)
                .body(payload)
                .retrieve().toBodilessEntity();
    }

    private URI dingtalkEndpoint(URI endpoint, String signSecret) {
        if (blank(signSecret)) return endpoint;
        long timestamp = System.currentTimeMillis();
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(signSecret.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
            String value = timestamp + "\n" + signSecret;
            String signature = Base64.getEncoder().encodeToString(mac.doFinal(value.getBytes(StandardCharsets.UTF_8)));
            return UriComponentsBuilder.fromUri(endpoint).queryParam("timestamp", timestamp)
                    .queryParam("sign", signature)
                    .build().encode().toUri();
        } catch (Exception exception) {
            throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "钉钉加签配置无效");
        }
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

    private void deliver(String channelKey, String channel, String text, boolean enabled, Runnable action) {
        if (!enabled) {
            saveDelivery(new NotificationDelivery(channelKey, text), NotificationDelivery.Status.SKIPPED, null);
            return;
        }
        try {
            action.run();
            saveDelivery(new NotificationDelivery(channelKey, text), NotificationDelivery.Status.SUCCESS, null);
        } catch (ApiException exception) {
            saveDelivery(new NotificationDelivery(channelKey, text), NotificationDelivery.Status.FAILED, safeProviderMessage(exception.getMessage()));
            log.warn("{} notification failed: {}", channel, exception.getMessage());
        } catch (Exception exception) {
            saveDelivery(new NotificationDelivery(channelKey, text), NotificationDelivery.Status.FAILED, exception.getClass().getSimpleName());
            log.warn("{} notification failed: {}", channel, exception.getClass().getSimpleName());
        }
    }

    private void deliverSync(String channelKey, String channel, String text, Runnable action) {
        NotificationDelivery delivery = new NotificationDelivery(channelKey, text);
        try {
            action.run();
            saveDelivery(delivery, NotificationDelivery.Status.SUCCESS, null);
        } catch (ApiException exception) {
            saveDelivery(delivery, NotificationDelivery.Status.FAILED, safeProviderMessage(exception.getMessage()));
            throw exception;
        } catch (Exception exception) {
            saveDelivery(delivery, NotificationDelivery.Status.FAILED, exception.getClass().getSimpleName());
            throw new ApiException(HttpStatus.BAD_GATEWAY, "通知发送失败，请检查通道配置和网络连通性");
        }
    }

    private void deliverSync(NotificationDelivery delivery, String channelKey, String channel, Runnable action) {
        delivery.setAttempts(delivery.getAttempts() + 1);
        try {
            action.run();
            saveDelivery(delivery, NotificationDelivery.Status.SUCCESS, null);
        } catch (ApiException exception) {
            saveDelivery(delivery, NotificationDelivery.Status.FAILED, safeProviderMessage(exception.getMessage()));
            throw exception;
        } catch (Exception exception) {
            saveDelivery(delivery, NotificationDelivery.Status.FAILED, exception.getClass().getSimpleName());
            throw new ApiException(HttpStatus.BAD_GATEWAY, "通知重试失败，请检查通道配置和网络连通性");
        }
    }

    private void saveDelivery(NotificationDelivery delivery, NotificationDelivery.Status status, String error) {
        if (deliveries == null) return;
        delivery.setStatus(status);
        delivery.setError(error);
        delivery.setFinishedAt(java.time.Instant.now());
        deliveries.save(delivery);
    }

    private void requireEnabled(boolean enabled) {
        if (!enabled) throw new ApiException(HttpStatus.BAD_REQUEST, "请先启用该通知通道");
    }

    private String brandName() {
        String value = settings.publicBrand().siteName();
        return value == null || value.isBlank() ? "星辰监控" : value.trim();
    }

    private boolean blank(String value) { return value == null || value.isBlank(); }

    private static SimpleClientHttpRequestFactory requestFactory() {
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout(Duration.ofSeconds(5));
        factory.setReadTimeout(Duration.ofSeconds(10));
        return factory;
    }

    public record TestResult(String channel, String message) {}
    public record NotificationDeliveryView(Long id, String channel, String status, String message, String error,
                                           int attempts, java.time.Instant createdAt, java.time.Instant finishedAt) {}
    private record WebhookResponse(Integer errcode, String errmsg) {}
}
