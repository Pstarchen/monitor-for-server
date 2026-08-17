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
    private int metricRetentionDays = 30;
    private int deviceOfflineAfterSeconds = 30;
    private boolean redisEnabled;
    private String allowedOrigins = "http://localhost:5173";
    private Notification notification = new Notification();

    @Getter
    @Setter
    public static class Notification {
        private String emailFrom;
        private String emailTo;
        private String dingtalkWebhookUrl;
        private String wecomWebhookUrl;
    }
}

