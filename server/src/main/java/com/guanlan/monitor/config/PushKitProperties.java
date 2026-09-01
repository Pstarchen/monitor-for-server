package com.guanlan.monitor.config;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

@Getter
@Setter
@Component
@ConfigurationProperties(prefix = "app.push-kit")
public class PushKitProperties {
    private boolean enabled;
    private String projectId = "";
    private String keyId = "";
    private String subAccount = "";
    private String privateKey = "";
    private String category = "MARKETING";
    private int ttlSeconds = 86400;
    private int batchSize = 50;
    private int maxAttempts = 5;
}
