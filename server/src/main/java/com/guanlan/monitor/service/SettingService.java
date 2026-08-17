package com.guanlan.monitor.service;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.config.AppProperties;
import com.guanlan.monitor.domain.SystemSetting;
import com.guanlan.monitor.repository.SystemSettingRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
@RequiredArgsConstructor
public class SettingService {
    private static final String RETENTION_DAYS = "metric.retention_days";
    private static final String OFFLINE_SECONDS = "device.offline_after_seconds";
    private static final String COLLECTION_SECONDS = "agent.default_collection_seconds";

    private final SystemSettingRepository settings;
    private final AppProperties properties;
    private final AuditService audit;

    @Transactional(readOnly = true)
    public View get() {
        return new View(
                intValue(RETENTION_DAYS, properties.getMetricRetentionDays()),
                intValue(OFFLINE_SECONDS, properties.getDeviceOfflineAfterSeconds()),
                intValue(COLLECTION_SECONDS, 3),
                configured(properties.getNotification().getEmailTo()),
                configured(properties.getNotification().getDingtalkWebhookUrl()),
                configured(properties.getNotification().getWecomWebhookUrl())
        );
    }

    @Transactional
    public View update(Update request) {
        if (request.metricRetentionDays() < 1 || request.metricRetentionDays() > 3650
                || request.deviceOfflineAfterSeconds() < 5 || request.deviceOfflineAfterSeconds() > 3600
                || request.defaultCollectionSeconds() < 1 || request.defaultCollectionSeconds() > 60) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "配置值超出允许范围");
        }
        save(RETENTION_DAYS, request.metricRetentionDays());
        save(OFFLINE_SECONDS, request.deviceOfflineAfterSeconds());
        save(COLLECTION_SECONDS, request.defaultCollectionSeconds());
        audit.record("SETTINGS_UPDATE", "system", "更新数据留存、离线判定与默认采集周期");
        return get();
    }

    public int retentionDays() { return intValue(RETENTION_DAYS, properties.getMetricRetentionDays()); }
    public int offlineSeconds() { return intValue(OFFLINE_SECONDS, properties.getDeviceOfflineAfterSeconds()); }

    private void save(String key, int value) { settings.save(new SystemSetting(key, Integer.toString(value))); }

    private int intValue(String key, int fallback) {
        return settings.findById(key).map(SystemSetting::getValue).map(value -> {
            try { return Integer.parseInt(value); } catch (NumberFormatException ignored) { return fallback; }
        }).orElse(fallback);
    }

    private boolean configured(String value) { return value != null && !value.isBlank(); }

    public record View(int metricRetentionDays, int deviceOfflineAfterSeconds, int defaultCollectionSeconds,
                       boolean emailConfigured, boolean dingtalkConfigured, boolean wecomConfigured) {}
    public record Update(int metricRetentionDays, int deviceOfflineAfterSeconds, int defaultCollectionSeconds) {}
}

