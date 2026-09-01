package com.guanlan.monitor.realtime;

import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.RequiredArgsConstructor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

@Component
@RequiredArgsConstructor
public class RealtimeEventDispatcher {
    private static final Logger log = LoggerFactory.getLogger(RealtimeEventDispatcher.class);
    private final ObjectMapper mapper;
    private final ReliableRealtimeWebSocketHandler sockets;

    public void dispatch(String json) {
        try {
            sockets.broadcast(mapper.readValue(json, RealtimeEventEnvelope.class));
        } catch (Exception exception) {
            log.warn("Discarding malformed realtime transport message: {}", exception.getClass().getSimpleName());
        }
    }

    public void dispatch(RealtimeEventEnvelope event) {
        sockets.broadcast(event);
    }
}
