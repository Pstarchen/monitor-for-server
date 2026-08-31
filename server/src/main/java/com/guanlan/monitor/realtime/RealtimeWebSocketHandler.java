package com.guanlan.monitor.realtime;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.service.DeviceAccessService;
import lombok.RequiredArgsConstructor;
import org.springframework.security.core.Authentication;
import org.springframework.stereotype.Component;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.handler.TextWebSocketHandler;

import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

@Component
@RequiredArgsConstructor
public class RealtimeWebSocketHandler extends TextWebSocketHandler {
    private final ObjectMapper mapper;
    private final DeviceAccessService access;
    private final Set<WebSocketSession> sessions = ConcurrentHashMap.newKeySet();

    @Override
    public void afterConnectionEstablished(WebSocketSession session) {
        sessions.add(session);
    }

    @Override
    public void afterConnectionClosed(WebSocketSession session, CloseStatus status) {
        sessions.remove(session);
    }

    public void broadcast(String type, String deviceId) {
        try {
            TextMessage message = new TextMessage(mapper.writeValueAsString(
                    java.util.Map.of("type", type, "payload", java.util.Map.of("deviceId", deviceId))));
            for (WebSocketSession session : sessions) {
                if (!session.isOpen()) {
                    sessions.remove(session);
                    continue;
                }
                if (!(session.getPrincipal() instanceof Authentication authentication)
                        || !access.canView(authentication, deviceId)) continue;
                try {
                    synchronized (session) {
                        session.sendMessage(message);
                    }
                } catch (Exception ignored) {
                    sessions.remove(session);
                }
            }
        } catch (Exception ignored) {
            // Persistence is authoritative; clients fall back to polling.
        }
    }
}

