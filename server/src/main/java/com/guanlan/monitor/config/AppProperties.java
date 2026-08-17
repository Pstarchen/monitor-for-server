package com.guanlan.monitor.config;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.annotation.Configuration;

@Getter
@Setter
@Configuration
@ConfigurationProperties(prefix = "app")
public class AppProperties {
    private String timezone = "Asia/Shanghai";
    private String bootstrapAdminUsername;
    private String bootstrapAdminPassword;
    private String siteName = "观澜监控";
    private String publicBaseUrl = "";
    private String settingsEncryptionKey;
    private int metricRetentionDays = 30;
    private int deviceOfflineAfterSeconds = 30;
    private boolean redisEnabled;
    private String allowedOrigins = "http://localhost:5173";
    private Notification notification = new Notification();

    @Getter
    @Setter
    public static class Notification {
        private String smtpHost;
        private int smtpPort = 587;
        private String smtpUsername;
        private String smtpPassword;
        private boolean smtpAuth = true;
        private boolean smtpStartTls = true;
        private String emailFrom;
        private String emailTo;
        private String dingtalkWebhookUrl;
        private String wecomWebhookUrl;
    }
}
