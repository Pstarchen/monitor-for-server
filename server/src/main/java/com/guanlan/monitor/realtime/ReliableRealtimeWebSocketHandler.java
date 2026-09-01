package com.guanlan.monitor.realtime;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.service.DeviceAccessService;
import com.guanlan.monitor.config.RealtimeProperties;
import lombok.RequiredArgsConstructor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.security.core.Authentication;
import org.springframework.stereotype.Component;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.handler.TextWebSocketHandler;

import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

@Component
@RequiredArgsConstructor
public class ReliableRealtimeWebSocketHandler extends TextWebSocketHandler {
    private static final Logger log = LoggerFactory.getLogger(ReliableRealtimeWebSocketHandler.class);
    private static final String LAST_EVENT_ID = "realtime.lastEventId";
    private static final String AUTHENTICATION = "realtime.authentication";
    private static final String AUTHENTICATION_CHECKED_AT = "realtime.authenticationCheckedAt";
    private final ObjectMapper mapper;
    private final DeviceAccessService access;
    private final RealtimeOutboxService outbox;
    private final RealtimeSessionAuthorizer authorizer;
    private final RealtimeProperties properties;
    private final Set<WebSocketSession> sessions = ConcurrentHashMap.newKeySet();

    @Override
    public void afterConnectionEstablished(WebSocketSession session) {
        sessions.add(session);
        synchronized (session) {
            Object cursor = session.getAttributes().get(RealtimeTicketHandshakeInterceptor.AFTER_EVENT_ID);
            String after = cursor instanceof String value ? value : outbox.latestEventId();
            session.getAttributes().put(LAST_EVENT_ID, after);
            Authentication authentication = refreshAuthentication(session);
            if (authentication == null) {
                close(session, CloseStatus.POLICY_VIOLATION);
                return;
            }
            try {
                RealtimeOutboxService.ReplayPage replay = outbox.replay(authentication, after, 500);
                for (RealtimeEventEnvelope event : replay.events()) sendEventLocked(session, event);
                if (replay.resyncRequired()) {
                    sendEventLocked(session, outbox.resyncRequired("cursor_expired", replay.latestEventId()));
                    sessions.remove(session);
                    close(session, CloseStatus.NORMAL);
                    return;
                }
                session.getAttributes().put(LAST_EVENT_ID, replay.nextEventId());
                sendLocked(session, Map.of("type", "replay.completed",
                        "nextEventId", replay.nextEventId() == null ? "" : replay.nextEventId(),
                        "latestEventId", replay.latestEventId() == null ? "" : replay.latestEventId(),
                        "hasMore", replay.hasMore()));
            } catch (Exception exception) {
                log.debug("Realtime replay failed for {}: {}", session.getId(), exception.getClass().getSimpleName());
                sessions.remove(session);
                close(session, CloseStatus.SERVER_ERROR);
            }
        }
    }

    @Override
    public void afterConnectionClosed(WebSocketSession session, CloseStatus status) {
        sessions.remove(session);
    }

    @Override
    public void handleTransportError(WebSocketSession session, Throwable exception) {
        sessions.remove(session);
        close(session, CloseStatus.SERVER_ERROR);
    }

    public void broadcast(RealtimeEventEnvelope event) {
        for (WebSocketSession session : sessions) {
            if (!session.isOpen()) {
                sessions.remove(session);
                continue;
            }
            Authentication authentication = refreshAuthentication(session);
            String deviceId = event.payload() == null ? null : event.payload().path("deviceId").asText(null);
            if (authentication == null || deviceId != null && !access.canView(authentication, deviceId)) continue;
            try {
                synchronized (session) {
                    sendEventLocked(session, event);
                }
            } catch (Exception exception) {
                sessions.remove(session);
                close(session, CloseStatus.SERVER_ERROR);
            }
        }
    }

    private Authentication refreshAuthentication(WebSocketSession session) {
        Object value = session.getAttributes().get(AUTHENTICATION);
        Authentication current = value instanceof Authentication authentication ? authentication
                : session.getPrincipal() instanceof Authentication authentication ? authentication : null;
        if (current == null) return null;
        Object checked = session.getAttributes().get(AUTHENTICATION_CHECKED_AT);
        long checkedAt = checked instanceof Long timestamp ? timestamp : 0L;
        long now = System.currentTimeMillis();
        if (now - checkedAt < Math.max(1, properties.getPermissionRecheckSeconds()) * 1000L) return current;
        Authentication refreshed = authorizer.refresh(current).orElse(null);
        if (refreshed == null) {
            close(session, CloseStatus.POLICY_VIOLATION);
            return null;
        }
        session.getAttributes().put(AUTHENTICATION, refreshed);
        session.getAttributes().put(AUTHENTICATION_CHECKED_AT, now);
        return refreshed;
    }

    private void sendEventLocked(WebSocketSession session, RealtimeEventEnvelope event) throws Exception {
        String lastEventId = session.getAttributes().get(LAST_EVENT_ID) instanceof String value ? value : null;
        if (event.eventId().equals(lastEventId)) return;
        sendLocked(session, event);
        session.getAttributes().put(LAST_EVENT_ID, event.eventId());
    }

    private void sendLocked(WebSocketSession session, Object value) throws Exception {
        if (session.isOpen()) session.sendMessage(new TextMessage(mapper.writeValueAsString(value)));
    }

    private void close(WebSocketSession session, CloseStatus status) {
        try {
            if (session.isOpen()) session.close(status);
        } catch (Exception ignored) {
            // The transport is already gone.
        }
    }
}
