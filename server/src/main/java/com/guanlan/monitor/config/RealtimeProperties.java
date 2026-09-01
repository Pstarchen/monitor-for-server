package com.guanlan.monitor.config;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

@Getter
@Setter
@Component
@ConfigurationProperties(prefix = "app.realtime")
public class RealtimeProperties {
    private boolean enabled = true;
    private String redisChannel = "monitor:realtime:v1";
    private int outboxBatchSize = 100;
    private int replayBatchSize = 1000;
    private int retentionHours = 24;
    private int ticketTtlSeconds = 60;
    private int permissionRecheckSeconds = 30;
}
