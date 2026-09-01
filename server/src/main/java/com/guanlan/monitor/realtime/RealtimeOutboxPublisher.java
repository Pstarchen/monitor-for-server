package com.guanlan.monitor.realtime;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.config.AppProperties;
import com.guanlan.monitor.config.RealtimeProperties;
import com.guanlan.monitor.domain.RealtimeOutboxEvent;
import com.guanlan.monitor.repository.RealtimeOutboxRepository;
import lombok.RequiredArgsConstructor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.time.Duration;
import java.time.Instant;
import java.util.List;

@Component
@RequiredArgsConstructor
public class RealtimeOutboxPublisher {
    private static final Logger log = LoggerFactory.getLogger(RealtimeOutboxPublisher.class);
    private final RealtimeOutboxRepository events;
    private final RealtimeOutboxService outbox;
    private final RealtimeEventDispatcher dispatcher;
    private final StringRedisTemplate redis;
    private final ObjectMapper mapper;
    private final AppProperties appProperties;
    private final RealtimeProperties properties;

    @Scheduled(fixedDelayString = "${app.realtime.publisher-delay-ms:250}", initialDelay = 2_000)
    @Transactional
    public void publishPending() {
        int batchSize = Math.min(Math.max(properties.getOutboxBatchSize(), 1), 500);
        List<RealtimeOutboxEvent> pending = events.lockPending(Instant.now(), PageRequest.of(0, batchSize));
        for (RealtimeOutboxEvent event : pending) publish(event);
    }

    @Scheduled(cron = "${app.realtime.cleanup-cron:0 35 3 * * *}")
    @Transactional
    public void cleanupPublished() {
        int retentionHours = Math.max(properties.getRetentionHours(), 1);
        events.deleteCompletedBefore(Instant.now().minus(Duration.ofHours(retentionHours)));
    }

    private void publish(RealtimeOutboxEvent event) {
        try {
            RealtimeEventEnvelope envelope = outbox.envelope(event);
            String json = mapper.writeValueAsString(envelope);
            if (appProperties.isRedisEnabled()) {
                redis.convertAndSend(properties.getRedisChannel(), json);
            } else {
                dispatcher.dispatch(envelope);
            }
            event.setPublishedAt(Instant.now());
            event.setLastError(null);
            event.setPublishAttempts(event.getPublishAttempts() + 1);
        } catch (Exception exception) {
            int attempts = event.getPublishAttempts() + 1;
            long delay = Math.min(60, 1L << Math.min(attempts, 6));
            event.setPublishAttempts(attempts);
            event.setAvailableAt(Instant.now().plusSeconds(delay));
            event.setLastError(safeError(exception));
            log.warn("Realtime outbox publish failed for {}: {}", event.getEventId(), exception.getClass().getSimpleName());
        }
    }

    private String safeError(Exception exception) {
        String value = exception.getClass().getSimpleName() + ": " + String.valueOf(exception.getMessage());
        value = value.replaceAll("[\\r\\n\\t]+", " ");
        return value.length() > 500 ? value.substring(0, 500) : value;
    }
}
