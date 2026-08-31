package com.guanlan.monitor.realtime;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.service.DeviceAccessService;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.security.core.Authentication;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class RealtimeWebSocketHandlerTest {
    @Mock DeviceAccessService access;
    @Mock WebSocketSession allowedSession;
    @Mock WebSocketSession deniedSession;
    @Mock Authentication allowedAuthentication;
    @Mock Authentication deniedAuthentication;

    @Test
    void broadcastsOnlyMinimalEventsToSessionsThatCanViewTheDevice() throws Exception {
        RealtimeWebSocketHandler handler = new RealtimeWebSocketHandler(new ObjectMapper(), access);
        when(allowedSession.isOpen()).thenReturn(true);
        when(deniedSession.isOpen()).thenReturn(true);
        when(allowedSession.getPrincipal()).thenReturn(allowedAuthentication);
        when(deniedSession.getPrincipal()).thenReturn(deniedAuthentication);
        when(access.canView(allowedAuthentication, "server-a")).thenReturn(true);
        when(access.canView(deniedAuthentication, "server-a")).thenReturn(false);
        handler.afterConnectionEstablished(allowedSession);
        handler.afterConnectionEstablished(deniedSession);

        handler.broadcast("metric.updated", "server-a");

        ArgumentCaptor<TextMessage> message = ArgumentCaptor.forClass(TextMessage.class);
        verify(allowedSession).sendMessage(message.capture());
        verify(deniedSession, never()).sendMessage(any());
        var event = new ObjectMapper().readTree(message.getValue().getPayload());
        assertThat(event.path("type").asText()).isEqualTo("metric.updated");
        assertThat(event.path("payload").path("deviceId").asText()).isEqualTo("server-a");
        assertThat(event.path("payload").size()).isEqualTo(1);
    }
}
