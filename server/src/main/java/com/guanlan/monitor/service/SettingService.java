package com.guanlan.monitor.service;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.config.AppProperties;
import com.guanlan.monitor.domain.SystemSetting;
import com.guanlan.monitor.repository.SystemSettingRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.multipart.MultipartFile;

import java.net.URI;
import java.time.DateTimeException;
import java.time.ZoneId;
import java.util.Set;

@Service
@RequiredArgsConstructor
public class SettingService {
    private static final String RETENTION_DAYS = "metric.retention_days";
    private static final String OFFLINE_SECONDS = "device.offline_after_seconds";
    private static final String COLLECTION_SECONDS = "agent.default_collection_seconds";
    private static final String SITE_NAME = "system.site_name";
    private static final String SITE_ICON_URL = "system.site_icon_url";
    private static final String DEFAULT_SITE_ICON_URL = "/brand-icon.png";
    private static final String UPLOADED_SITE_ICON_URL = "/api/settings/site-icon";
    private static final String PUBLIC_BASE_URL = "system.public_base_url";
    private static final String TIMEZONE = "system.timezone";
    private static final String ENABLE_MCP = "system.enable_mcp";
    private static final String EMAIL_ENABLED = "notification.email.enabled";
    private static final String EMAIL_HOST = "notification.email.host";
    private static final String EMAIL_PORT = "notification.email.port";
    private static final String EMAIL_USERNAME = "notification.email.username";
    private static final String EMAIL_PASSWORD = "notification.email.password";
    private static final String EMAIL_FROM = "notification.email.from";
    private static final String EMAIL_RECIPIENTS = "notification.email.recipients";
    private static final String EMAIL_AUTH = "notification.email.auth";
    private static final String EMAIL_START_TLS = "notification.email.start_tls";
    private static final String DINGTALK_ENABLED = "notification.dingtalk.enabled";
    private static final String DINGTALK_WEBHOOK = "notification.dingtalk.webhook";
    private static final String DINGTALK_KEYWORD = "notification.dingtalk.keyword";
    private static final String DINGTALK_SIGN_SECRET = "notification.dingtalk.sign_secret";
    private static final String WECOM_ENABLED = "notification.wecom.enabled";
    private static final String WECOM_WEBHOOK = "notification.wecom.webhook";
    private static final String WECOM_KEYWORD = "notification.wecom.keyword";
    private static final String WECOM_SIGN_SECRET = "notification.wecom.sign_secret";
    private static final String GENERIC_ENABLED = "notification.generic.enabled";
    private static final String GENERIC_WEBHOOK = "notification.generic.webhook";
    private static final String GENERIC_FORMAT = "notification.generic.format";

    private final SystemSettingRepository settings;
    private final AppProperties properties;
    private final AuditService audit;
    private final SecretValueCodec secretCodec;
    private final SiteIconStorageService siteIconStorage;
    private final PushKitConfigurationService pushKitConfigurations;

    @Transactional(readOnly = true)
    public View get() {
        NotificationRuntime notification = notificationRuntime();
        return new View(
                intValue(RETENTION_DAYS, properties.getMetricRetentionDays()),
                intValue(OFFLINE_SECONDS, properties.getDeviceOfflineAfterSeconds()),
                intValue(COLLECTION_SECONDS, 3),
                stringValue(SITE_NAME, properties.getSiteName()),
                stringValue(SITE_ICON_URL, DEFAULT_SITE_ICON_URL),
                stringValue(PUBLIC_BASE_URL, properties.getPublicBaseUrl()),
                stringValue(TIMEZONE, properties.getTimezone()),
                booleanValue(ENABLE_MCP, properties.isEnableMcp()),
                secretCodec.available(),
                emailView(notification.email()),
                webhookView(notification.dingtalk()),
                webhookView(notification.wecom()),
                webhookView(notification.generic()),
                pushKitConfigurations.get()
        );
    }

    @Transactional
    public View update(Update request) {
        validate(request);
        save(RETENTION_DAYS, request.metricRetentionDays());
        save(OFFLINE_SECONDS, request.deviceOfflineAfterSeconds());
        save(COLLECTION_SECONDS, request.defaultCollectionSeconds());
        save(SITE_NAME, request.siteName().trim());
        String siteIconUrl = normalizeSiteIconUrl(request.siteIconUrl());
        if (!UPLOADED_SITE_ICON_URL.equals(siteIconUrl)) siteIconStorage.clear();
        save(SITE_ICON_URL, siteIconUrl);
        save(PUBLIC_BASE_URL, normalizeBaseUrl(request.publicBaseUrl()));
        save(TIMEZONE, request.timezone().trim());
        save(ENABLE_MCP, request.enableMcp());
        updateEmail(request.email());
        updateWebhook(DINGTALK_ENABLED, DINGTALK_WEBHOOK, DINGTALK_KEYWORD, DINGTALK_SIGN_SECRET, request.dingtalk());
        updateWebhook(WECOM_ENABLED, WECOM_WEBHOOK, WECOM_KEYWORD, WECOM_SIGN_SECRET, request.wecom());
        updateWebhook(GENERIC_ENABLED, GENERIC_WEBHOOK, null, null, request.generic());
        save(GENERIC_FORMAT, normalizeWebhookFormat(request.generic().payloadFormat()));
        if (request.pushKit() != null) pushKitConfigurations.update(request.pushKit());
        audit.record("SETTINGS_UPDATE", "system", "更新系统策略与通知通道配置");
        return get();
    }

    @Transactional
    public View uploadSiteIcon(MultipartFile file) {
        siteIconStorage.store(file);
        save(SITE_ICON_URL, UPLOADED_SITE_ICON_URL);
        audit.record("SITE_ICON_UPLOAD", "system", "上传网站图标");
        return get();
    }

    @Transactional(readOnly = true)
    public NotificationRuntime notificationRuntime() {
        AppProperties.Notification fallback = properties.getNotification();
        EmailRuntime email = new EmailRuntime(
                booleanValue(EMAIL_ENABLED, configured(fallback.getEmailTo())),
                stringValue(EMAIL_HOST, fallback.getSmtpHost()),
                intValue(EMAIL_PORT, fallback.getSmtpPort()),
                stringValue(EMAIL_USERNAME, fallback.getSmtpUsername()),
                secretValue(EMAIL_PASSWORD, fallback.getSmtpPassword()),
                stringValue(EMAIL_FROM, fallback.getEmailFrom()),
                stringValue(EMAIL_RECIPIENTS, fallback.getEmailTo()),
                booleanValue(EMAIL_AUTH, fallback.isSmtpAuth()),
                booleanValue(EMAIL_START_TLS, fallback.isSmtpStartTls()),
                source(EMAIL_PASSWORD, fallback.getSmtpPassword())
        );
        WebhookRuntime dingtalk = new WebhookRuntime(
                booleanValue(DINGTALK_ENABLED, configured(fallback.getDingtalkWebhookUrl())),
                secretValue(DINGTALK_WEBHOOK, fallback.getDingtalkWebhookUrl()),
                source(DINGTALK_WEBHOOK, fallback.getDingtalkWebhookUrl()),
                stringValue(DINGTALK_KEYWORD, fallback.getDingtalkKeyword()),
                secretValue(DINGTALK_SIGN_SECRET, fallback.getDingtalkSignSecret())
        );
        WebhookRuntime wecom = new WebhookRuntime(
                booleanValue(WECOM_ENABLED, configured(fallback.getWecomWebhookUrl())),
                secretValue(WECOM_WEBHOOK, fallback.getWecomWebhookUrl()),
                source(WECOM_WEBHOOK, fallback.getWecomWebhookUrl()),
                stringValue(WECOM_KEYWORD, ""), secretValue(WECOM_SIGN_SECRET, "")
        );
        WebhookRuntime generic = new WebhookRuntime(
                booleanValue(GENERIC_ENABLED, configured(fallback.getGenericWebhookUrl())),
                secretValue(GENERIC_WEBHOOK, fallback.getGenericWebhookUrl()),
                source(GENERIC_WEBHOOK, fallback.getGenericWebhookUrl()),
                "", "", normalizeWebhookFormat(stringValue(GENERIC_FORMAT, fallback.getGenericWebhookFormat()))
        );
        return new NotificationRuntime(email, dingtalk, wecom, generic);
    }

    public int retentionDays() { return intValue(RETENTION_DAYS, properties.getMetricRetentionDays()); }
    public int offlineSeconds() { return intValue(OFFLINE_SECONDS, properties.getDeviceOfflineAfterSeconds()); }
    public int agentCollectionSeconds() { return intValue(COLLECTION_SECONDS, 3); }
    public boolean mcpEnabled() { return booleanValue(ENABLE_MCP, properties.isEnableMcp()); }

    @Transactional(readOnly = true)
    public AgentBootstrapView agentBootstrap() {
        return new AgentBootstrapView(
                stringValue(PUBLIC_BASE_URL, properties.getPublicBaseUrl()),
                agentCollectionSeconds()
        );
    }

    @Transactional(readOnly = true)
    public PublicBrandView publicBrand() {
        return new PublicBrandView(stringValue(SITE_NAME, properties.getSiteName()),
                stringValue(SITE_ICON_URL, DEFAULT_SITE_ICON_URL));
    }

    private void updateEmail(EmailUpdate email) {
        save(EMAIL_ENABLED, email.enabled());
        save(EMAIL_HOST, email.host().trim());
        save(EMAIL_PORT, email.port());
        save(EMAIL_USERNAME, email.username().trim());
        save(EMAIL_FROM, email.from().trim());
        save(EMAIL_RECIPIENTS, email.recipients().trim());
        save(EMAIL_AUTH, email.auth());
        save(EMAIL_START_TLS, email.startTls());
        updateSecret(EMAIL_PASSWORD, email.password(), email.clearPassword());
    }

    private void updateWebhook(String enabledKey, String secretKey, String keywordKey, String signSecretKey, WebhookUpdate webhook) {
        save(enabledKey, webhook.enabled());
        if (webhook.webhookUrl() != null && !webhook.webhookUrl().isBlank()) {
            validateWebhook(secretKey, webhook.webhookUrl());
        }
        updateSecret(secretKey, webhook.webhookUrl(), webhook.clearWebhook());
        if (webhook.keyword() != null && !webhook.keyword().isBlank()) {
            if (webhook.keyword().length() > 100) throw new ApiException(HttpStatus.BAD_REQUEST, "钉钉关键词不能超过 100 个字符");
            save(keywordKey, webhook.keyword().trim());
        }
        updateSecret(signSecretKey, webhook.signSecret(), webhook.clearSignSecret());
    }

    private void updateSecret(String key, String replacement, boolean clear) {
        if (key == null || key.isBlank()) return;
        if (clear) {
            if (settings.existsById(key)) settings.deleteById(key);
            return;
        }
        if (replacement == null || replacement.isBlank()) return;
        if (!secretCodec.available()) {
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "未配置设置加密密钥，无法保存通知凭据");
        }
        save(key, secretCodec.encrypt(replacement));
    }

    private void validate(Update request) {
        if (request == null || request.email() == null || request.dingtalk() == null || request.wecom() == null || request.generic() == null) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "设置内容不完整");
        }
        if (request.metricRetentionDays() < 1 || request.metricRetentionDays() > 3650
                || request.deviceOfflineAfterSeconds() < 5 || request.deviceOfflineAfterSeconds() > 3600
                || !Set.of(1, 3, 10, 30, 60).contains(request.defaultCollectionSeconds())) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "配置值超出允许范围");
        }
        if (request.siteName() == null || request.siteName().isBlank() || request.siteName().trim().length() > 60) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "站点名称长度应为 1-60 个字符");
        }
        if (request.timezone() == null || request.timezone().isBlank()) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "时区格式无效");
        }
        validateSiteIconUrl(request.siteIconUrl());
        validateBaseUrl(request.publicBaseUrl());
        try {
            ZoneId.of(request.timezone().trim());
        } catch (NullPointerException | DateTimeException exception) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "时区格式无效");
        }
        EmailUpdate email = request.email();
        if (email.host() == null || email.username() == null || email.from() == null || email.recipients() == null
                || email.port() < 1 || email.port() > 65535 || email.host().length() > 255
                || email.username().length() > 255 || email.from().length() > 255 || email.recipients().length() > 500) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "邮件配置值超出允许范围");
        }
        if (email.enabled() && (blank(email.host()) || blank(email.from()) || blank(email.recipients()))) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "启用邮件通知前请填写 SMTP 主机、发件人和收件人");
        }
        if (request.dingtalk().keyword() != null && request.dingtalk().keyword().length() > 100) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "钉钉关键词不能超过 100 个字符");
        }
        if (request.dingtalk().signSecret() != null && request.dingtalk().signSecret().length() > 255) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "钉钉加签密钥长度无效");
        }
        normalizeWebhookFormat(request.generic().payloadFormat());
    }

    private void validateBaseUrl(String value) {
        if (blank(value)) return;
        try {
            URI uri = URI.create(value.trim());
            boolean localHttp = "http".equalsIgnoreCase(uri.getScheme())
                    && Set.of("localhost", "127.0.0.1", "::1").contains(uri.getHost());
            boolean insecureHttp = "http".equalsIgnoreCase(uri.getScheme()) && properties.isAllowInsecureHttp();
            if (uri.getHost() == null || uri.getUserInfo() != null
                    || (uri.getPath() != null && !uri.getPath().isBlank() && !"/".equals(uri.getPath()))
                    || (!("https".equalsIgnoreCase(uri.getScheme()) || insecureHttp) && !localHttp)
                    || uri.getQuery() != null || uri.getFragment() != null) {
                throw new IllegalArgumentException();
            }
        } catch (IllegalArgumentException exception) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "公网入口必须是 HTTPS 地址，本地开发可使用 localhost HTTP");
        }
    }

    private void validateSiteIconUrl(String value) {
        if (blank(value)) return;
        String candidate = value.trim();
        if (candidate.length() > 500) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "网站图标地址不能超过 500 个字符");
        }
        if (candidate.startsWith("/")) {
            if (candidate.startsWith("//") || candidate.contains("\\") || candidate.chars().anyMatch(Character::isWhitespace)) {
                throw new ApiException(HttpStatus.BAD_REQUEST, "网站图标必须是站内路径或 HTTPS 图片地址");
            }
            return;
        }
        try {
            URI uri = URI.create(candidate);
            boolean secure = "https".equalsIgnoreCase(uri.getScheme());
            boolean insecure = "http".equalsIgnoreCase(uri.getScheme()) && properties.isAllowInsecureHttp();
            if (uri.getHost() == null || (!secure && !insecure) || uri.getUserInfo() != null || uri.getFragment() != null) {
                throw new IllegalArgumentException();
            }
        } catch (IllegalArgumentException exception) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "网站图标必须是站内路径或 HTTPS 图片地址");
        }
    }

    private String normalizeSiteIconUrl(String value) {
        return blank(value) ? DEFAULT_SITE_ICON_URL : value.trim();
    }

    private void validateWebhook(String key, String value) {
        if (GENERIC_WEBHOOK.equals(key)) {
            try {
                URI uri = URI.create(value.trim());
                boolean localHttp = "http".equalsIgnoreCase(uri.getScheme())
                        && Set.of("localhost", "127.0.0.1", "::1").contains(uri.getHost());
                boolean insecureHttp = "http".equalsIgnoreCase(uri.getScheme()) && properties.isAllowInsecureHttp();
                if (uri.getHost() == null || (!"https".equalsIgnoreCase(uri.getScheme()) && !insecureHttp && !localHttp)
                        || uri.getUserInfo() != null || uri.getFragment() != null) throw new IllegalArgumentException();
            } catch (IllegalArgumentException exception) {
                throw new ApiException(HttpStatus.BAD_REQUEST, "通用 Webhook 地址必须是 HTTPS 地址");
            }
            return;
        }
        String requiredHost = key.equals(DINGTALK_WEBHOOK) ? "oapi.dingtalk.com" : "qyapi.weixin.qq.com";
        try {
            URI uri = URI.create(value.trim());
            if (!"https".equalsIgnoreCase(uri.getScheme()) || !requiredHost.equalsIgnoreCase(uri.getHost())) {
                throw new IllegalArgumentException();
            }
        } catch (IllegalArgumentException exception) {
            String channel = key.equals(DINGTALK_WEBHOOK) ? "钉钉" : "企业微信";
            throw new ApiException(HttpStatus.BAD_REQUEST, channel + " Webhook 地址无效");
        }
    }

    private EmailView emailView(EmailRuntime email) {
        boolean complete = configured(email.host()) && configured(email.from()) && configured(email.recipients())
                && (!email.auth() || (configured(email.username()) && configured(email.password())));
        return new EmailView(email.enabled(), complete, email.source(), email.host(), email.port(), email.username(),
                email.from(), email.recipients(), email.auth(), email.startTls(), configured(email.password()));
    }

    private WebhookView webhookView(WebhookRuntime webhook) {
        return new WebhookView(webhook.enabled(), configured(webhook.url()), webhook.source(), configured(webhook.url()),
                webhook.keyword(), configured(webhook.keyword()), configured(webhook.signSecret()), webhook.payloadFormat());
    }

    private void save(String key, int value) { save(key, Integer.toString(value)); }
    private void save(String key, boolean value) { save(key, Boolean.toString(value)); }
    private void save(String key, String value) { settings.save(new SystemSetting(key, value == null ? "" : value)); }

    private String stringValue(String key, String fallback) {
        return settings.findById(key).map(SystemSetting::getValue).orElse(fallback == null ? "" : fallback);
    }

    private String secretValue(String key, String fallback) {
        return settings.findById(key).map(SystemSetting::getValue).map(secretCodec::decrypt).orElse(fallback);
    }

    private int intValue(String key, int fallback) {
        return settings.findById(key).map(SystemSetting::getValue).map(value -> {
            try { return Integer.parseInt(value); } catch (NumberFormatException ignored) { return fallback; }
        }).orElse(fallback);
    }

    private boolean booleanValue(String key, boolean fallback) {
        return settings.findById(key).map(SystemSetting::getValue).map(Boolean::parseBoolean).orElse(fallback);
    }

    private String source(String key, String fallback) {
        if (settings.existsById(key)) return "DATABASE";
        return configured(fallback) ? "ENVIRONMENT" : "NONE";
    }

    private String normalizeBaseUrl(String value) {
        if (blank(value)) return "";
        String normalized = value.trim();
        while (normalized.endsWith("/")) normalized = normalized.substring(0, normalized.length() - 1);
        return normalized;
    }

    private boolean configured(String value) { return !blank(value); }
    private boolean blank(String value) { return value == null || value.isBlank(); }

    private String normalizeWebhookFormat(String value) {
        String format = blank(value) ? "GENERIC_JSON" : value.trim().toUpperCase(java.util.Locale.ROOT);
        if (!Set.of("GENERIC_JSON", "SLACK", "DISCORD", "LARK", "PLAIN_TEXT").contains(format)) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "通用 Webhook 消息格式无效");
        }
        return format;
    }

    public record View(int metricRetentionDays, int deviceOfflineAfterSeconds, int defaultCollectionSeconds,
                       String siteName, String siteIconUrl, String publicBaseUrl, String timezone, boolean enableMcp, boolean secretStorageReady,
                       EmailView email, WebhookView dingtalk, WebhookView wecom, WebhookView generic,
                       PushKitConfigurationService.View pushKit) {}
    public record EmailView(boolean enabled, boolean configured, String source, String host, int port,
                            String username, String from, String recipients, boolean auth, boolean startTls,
                            boolean passwordConfigured) {}
    public record WebhookView(boolean enabled, boolean configured, String source, boolean webhookConfigured,
                              String keyword, boolean keywordConfigured, boolean signSecretConfigured,
                              String payloadFormat) {}
    public record Update(int metricRetentionDays, int deviceOfflineAfterSeconds, int defaultCollectionSeconds,
                         String siteName, String siteIconUrl, String publicBaseUrl, String timezone, boolean enableMcp, EmailUpdate email,
                         WebhookUpdate dingtalk, WebhookUpdate wecom, WebhookUpdate generic,
                         PushKitConfigurationService.Update pushKit) {
        public Update(int metricRetentionDays, int deviceOfflineAfterSeconds, int defaultCollectionSeconds,
                      String siteName, String siteIconUrl, String publicBaseUrl, String timezone, EmailUpdate email,
                      WebhookUpdate dingtalk, WebhookUpdate wecom) {
            this(metricRetentionDays, deviceOfflineAfterSeconds, defaultCollectionSeconds, siteName, siteIconUrl, publicBaseUrl, timezone, false, email, dingtalk, wecom, new WebhookUpdate(false, null, false), null);
        }
        public Update(int metricRetentionDays, int deviceOfflineAfterSeconds, int defaultCollectionSeconds,
                      String siteName, String siteIconUrl, String publicBaseUrl, String timezone, boolean enableMcp, EmailUpdate email,
                      WebhookUpdate dingtalk, WebhookUpdate wecom) {
            this(metricRetentionDays, deviceOfflineAfterSeconds, defaultCollectionSeconds, siteName, siteIconUrl, publicBaseUrl, timezone, enableMcp, email, dingtalk, wecom, new WebhookUpdate(false, null, false), null);
        }
    }
    public record EmailUpdate(boolean enabled, String host, int port, String username, String password,
                              boolean clearPassword, String from, String recipients, boolean auth, boolean startTls) {}
    public record WebhookUpdate(boolean enabled, String webhookUrl, boolean clearWebhook, String keyword,
                                String signSecret, boolean clearSignSecret, String payloadFormat) {
        public WebhookUpdate(boolean enabled, String webhookUrl, boolean clearWebhook) {
            this(enabled, webhookUrl, clearWebhook, null, null, false, "GENERIC_JSON");
        }
        public WebhookUpdate(boolean enabled, String webhookUrl, boolean clearWebhook, String keyword,
                             String signSecret, boolean clearSignSecret) {
            this(enabled, webhookUrl, clearWebhook, keyword, signSecret, clearSignSecret, "GENERIC_JSON");
        }
    }
    public record NotificationRuntime(EmailRuntime email, WebhookRuntime dingtalk, WebhookRuntime wecom, WebhookRuntime generic) {
        public NotificationRuntime(EmailRuntime email, WebhookRuntime dingtalk, WebhookRuntime wecom) {
            this(email, dingtalk, wecom, new WebhookRuntime(false, "", "NONE"));
        }
    }
    public record AgentBootstrapView(String publicBaseUrl, int defaultCollectionSeconds) {}
    public record PublicBrandView(String siteName, String siteIconUrl) {}
    public record EmailRuntime(boolean enabled, String host, int port, String username, String password,
                               String from, String recipients, boolean auth, boolean startTls, String source) {}
    public record WebhookRuntime(boolean enabled, String url, String source, String keyword, String signSecret, String payloadFormat) {
        public WebhookRuntime(boolean enabled, String url, String source) {
            this(enabled, url, source, "", "", "GENERIC_JSON");
        }
        public WebhookRuntime(boolean enabled, String url, String source, String keyword, String signSecret) {
            this(enabled, url, source, keyword, signSecret, "GENERIC_JSON");
        }
    }
}
