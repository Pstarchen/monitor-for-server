package com.guanlan.monitor.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.config.AppProperties;
import lombok.RequiredArgsConstructor;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Service;

import java.time.Duration;

@Service
@RequiredArgsConstructor
public class PresenceService {
    private final StringRedisTemplate redis;
    private final ObjectMapper mapper;
    private final AppProperties properties;

    public void markSeen(String deviceId, int offlineSeconds) {
        if (!properties.isRedisEnabled()) return;
        try {
            redis.opsForValue().set("monitor:device:" + deviceId + ":online", "1", Duration.ofSeconds(offlineSeconds));
        } catch (Exception ignored) {
            // Database lastSeenAt remains authoritative when Redis is unavailable.
        }
    }

    public void markLatest(String deviceId, Object latestMetric) {
        if (!properties.isRedisEnabled()) return;
        try {
            redis.opsForValue().set("monitor:device:" + deviceId + ":latest", mapper.writeValueAsString(latestMetric), Duration.ofMinutes(5));
        } catch (Exception ignored) {
            // The database remains authoritative when Redis is unavailable.
        }
    }
}

