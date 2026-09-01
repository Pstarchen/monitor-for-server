package com.guanlan.monitor.realtime;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.config.RealtimeProperties;
import com.guanlan.monitor.domain.RealtimeOutboxEvent;
import com.guanlan.monitor.repository.RealtimeOutboxRepository;
import com.guanlan.monitor.service.DeviceAccessService;
import com.guanlan.monitor.service.ControllerIdentityService;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.data.domain.Pageable;
import org.springframework.security.core.Authentication;

import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class RealtimeOutboxServiceTest {
    @Mock RealtimeOutboxRepository repository;
    @Mock DeviceAccessService access;
    @Mock Authentication authentication;
    @Mock ControllerIdentityService controllerIdentity;

    @Test
    void appendsMinimalEventWithServerGeneratedStableId() {
        RealtimeProperties properties = new RealtimeProperties();
        RealtimeOutboxService service = new RealtimeOutboxService(repository, new ObjectMapper(), access, properties, controllerIdentity);
        when(controllerIdentity.controllerId()).thenReturn("controller-1");
        when(repository.save(any())).thenAnswer(invocation -> invocation.getArgument(0));

        service.append("metric.updated", "metric", "42", "server-a", Map.of("metricId", 42));

        ArgumentCaptor<RealtimeOutboxEvent> captured = ArgumentCaptor.forClass(RealtimeOutboxEvent.class);
        verify(repository).save(captured.capture());
        assertThat(captured.getValue().getEventType()).isEqualTo("metric.updated");
        assertThat(captured.getValue().getEventId()).isNotBlank();
        assertThat(captured.getValue().getDeviceId()).isEqualTo("server-a");
        assertThat(captured.getValue().getPayloadJson()).isEqualTo("{\"metricId\":42}");
    }

    @Test
    void replayFiltersDeviceEventsAndPreservesStableEventIds() {
        RealtimeProperties properties = new RealtimeProperties();
        RealtimeOutboxService service = new RealtimeOutboxService(repository, new ObjectMapper(), access, properties, controllerIdentity);
        RealtimeOutboxEvent allowed = event(11, "11111111-1111-1111-1111-111111111111", "server-a");
        RealtimeOutboxEvent denied = event(12, "22222222-2222-2222-2222-222222222222", "server-b");
        when(repository.findTopByOrderByIdDesc()).thenReturn(Optional.of(denied));
        when(repository.findTopByOrderByIdAsc()).thenReturn(Optional.of(allowed));
        when(repository.findByIdGreaterThanOrderByIdAsc(any(), any(Pageable.class))).thenReturn(List.of(allowed, denied));
        when(access.visibleDeviceIds(authentication)).thenReturn(Set.of("server-a"));

        RealtimeOutboxService.ReplayPage replay = service.replay(authentication, null, 10);

        assertThat(replay.events()).extracting(RealtimeEventEnvelope::eventId)
                .containsExactly("11111111-1111-1111-1111-111111111111");
        assertThat(replay.nextEventId()).isEqualTo("22222222-2222-2222-2222-222222222222");
        assertThat(replay.latestEventId()).isEqualTo("22222222-2222-2222-2222-222222222222");
    }

    private RealtimeOutboxEvent event(long sequence, String eventId, String deviceId) {
        RealtimeOutboxEvent event = new RealtimeOutboxEvent();
        event.setId(sequence);
        event.setEventId(eventId);
        event.setEventType("device.status");
        event.setAggregateType("device-status");
        event.setAggregateId(Long.toString(sequence));
        event.setDeviceId(deviceId);
        event.setPayloadJson("{\"status\":\"ONLINE\"}");
        event.setOccurredAt(Instant.parse("2026-09-01T00:00:00Z"));
        return event;
    }
}
