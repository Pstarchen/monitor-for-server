package com.guanlan.monitor.realtime;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.config.RealtimeProperties;
import com.guanlan.monitor.domain.RealtimeOutboxEvent;
import com.guanlan.monitor.repository.RealtimeOutboxRepository;
import com.guanlan.monitor.service.ControllerIdentityService;
import com.guanlan.monitor.service.DeviceAccessService;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.PageRequest;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.Authentication;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

@Service
@RequiredArgsConstructor
public class RealtimeOutboxService {
    private final RealtimeOutboxRepository events;
    private final ObjectMapper mapper;
    private final DeviceAccessService access;
    private final RealtimeProperties properties;
    private final ControllerIdentityService controllerIdentity;

    @Transactional(propagation = Propagation.MANDATORY)
    public RealtimeOutboxEvent append(String type, String aggregateType, String aggregateId,
                                      String deviceId, Map<String, ?> payload) {
        RealtimeOutboxEvent event = new RealtimeOutboxEvent();
        event.setEventId(UUID.randomUUID().toString());
        event.setControllerId(controllerIdentity.controllerId());
        event.setEventType(required(type, "event type"));
        event.setAggregateType(required(aggregateType, "aggregate type"));
        event.setAggregateId(required(aggregateId, "aggregate id"));
        event.setDeviceId(normalize(deviceId));
        try {
            event.setPayloadJson(mapper.writeValueAsString(payload == null ? Map.of() : payload));
        } catch (Exception exception) {
            throw new IllegalStateException("Unable to serialize realtime event", exception);
        }
        return events.save(event);
    }

    @Transactional(readOnly = true)
    public ReplayPage replay(Authentication authentication, String afterEventId, int requestedLimit) {
        int replayLimit = Math.min(Math.max(properties.getReplayBatchSize(), 1), 1000);
        int limit = Math.min(Math.max(requestedLimit, 1), replayLimit);
        Cursor cursor = cursor(afterEventId);
        RealtimeOutboxEvent latest = events.findTopByOrderByIdDesc().orElse(null);
        RealtimeOutboxEvent oldest = events.findTopByOrderByIdAsc().orElse(null);
        String latestEventId = latest == null ? null : latest.getEventId();
        String oldestEventId = oldest == null ? null : oldest.getEventId();
        if (cursor.resyncRequired() || events.countByIdGreaterThan(cursor.sequence()) > replayLimit) {
            return new ReplayPage(List.of(), latestEventId, oldestEventId, latestEventId,
                    true, true, latest == null ? 0 : latest.getId());
        }

        Set<String> visible = access.visibleDeviceIds(authentication);
        List<RealtimeEventEnvelope> result = new ArrayList<>();
        long scanned = cursor.sequence();
        String nextEventId = afterEventId;
        long latestSequence = latest == null ? 0 : latest.getId();
        int pageSize = Math.min(500, Math.max(limit * 2, 50));
        while (result.size() < limit && scanned < latestSequence) {
            List<RealtimeOutboxEvent> page = events.findByIdGreaterThanOrderByIdAsc(scanned, PageRequest.of(0, pageSize));
            if (page.isEmpty()) break;
            for (RealtimeOutboxEvent event : page) {
                scanned = event.getId();
                nextEventId = event.getEventId();
                if (canView(visible, event.getDeviceId())) result.add(envelope(event));
                if (result.size() == limit) break;
            }
            if (page.size() < pageSize) break;
        }
        return new ReplayPage(List.copyOf(result), nextEventId, oldestEventId, latestEventId,
                scanned < latestSequence, false, scanned);
    }

    @Transactional(readOnly = true)
    public long latestSequence() {
        return events.findTopByOrderByIdDesc().map(RealtimeOutboxEvent::getId).orElse(0L);
    }

    @Transactional(readOnly = true)
    public String latestEventId() {
        return events.findTopByOrderByIdDesc().map(RealtimeOutboxEvent::getEventId).orElse(null);
    }

    public RealtimeEventEnvelope envelope(RealtimeOutboxEvent event) {
        try {
            JsonNode payload = mapper.readTree(event.getPayloadJson());
            return new RealtimeEventEnvelope(2, event.getEventId(), event.getEventType(),
                    event.getOccurredAt(), event.getControllerId(), payload);
        } catch (Exception exception) {
            throw new IllegalStateException("Unable to deserialize realtime event " + event.getEventId(), exception);
        }
    }

    public RealtimeTransportMessage transport(RealtimeOutboxEvent event) {
        return new RealtimeTransportMessage(event.getId(), event.getDeviceId(), envelope(event));
    }

    public RealtimeEventEnvelope resyncRequired(String reason, String latestEventId) {
        JsonNode payload = mapper.valueToTree(Map.of(
                "reason", reason,
                "latestEventId", latestEventId == null ? "" : latestEventId));
        return new RealtimeEventEnvelope(2, latestEventId == null ? controllerIdentity.controllerId() : latestEventId,
                "resync.required", Instant.now(), controllerIdentity.controllerId(), payload);
    }

    private boolean canView(Set<String> visible, String deviceId) {
        return deviceId == null || visible == null || visible.contains(deviceId);
    }

    private String required(String value, String field) {
        if (value == null || value.isBlank()) throw new IllegalArgumentException(field + " is required");
        return value.trim();
    }

    private String normalize(String value) {
        return value == null || value.isBlank() ? null : value.trim();
    }

    private Cursor cursor(String eventId) {
        if (eventId == null || eventId.isBlank()) return new Cursor(0, false);
        String normalized = eventId.trim();
        try {
            if (!UUID.fromString(normalized).toString().equalsIgnoreCase(normalized)) throw new IllegalArgumentException();
        } catch (IllegalArgumentException exception) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "实时事件 ID 格式无效");
        }
        return events.findByEventId(normalized)
                .map(event -> new Cursor(event.getId(), false))
                .orElseGet(() -> new Cursor(latestSequence(), true));
    }

    private record Cursor(long sequence, boolean resyncRequired) {}
    public record ReplayPage(List<RealtimeEventEnvelope> events, String nextEventId,
                             String oldestEventId, String latestEventId, boolean hasMore,
                             boolean resyncRequired,
                             @com.fasterxml.jackson.annotation.JsonIgnore long nextSequence) {}
}
