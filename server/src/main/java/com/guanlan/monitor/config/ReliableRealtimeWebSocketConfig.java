package com.guanlan.monitor.config;

import com.guanlan.monitor.realtime.RealtimeHandshakeHandler;
import com.guanlan.monitor.realtime.RealtimeTicketHandshakeInterceptor;
import com.guanlan.monitor.realtime.RealtimeTicketService;
import com.guanlan.monitor.realtime.ReliableRealtimeWebSocketHandler;
import lombok.RequiredArgsConstructor;
import org.springframework.context.annotation.Configuration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.web.socket.config.annotation.WebSocketConfigurer;
import org.springframework.web.socket.config.annotation.WebSocketHandlerRegistry;

import java.util.Arrays;

@Configuration
@ConditionalOnProperty(prefix = "app.realtime", name = "enabled", havingValue = "true", matchIfMissing = true)
@RequiredArgsConstructor
public class ReliableRealtimeWebSocketConfig implements WebSocketConfigurer {
    private final ReliableRealtimeWebSocketHandler handler;
    private final RealtimeTicketService tickets;
    private final AppProperties properties;

    @Override
    public void registerWebSocketHandlers(WebSocketHandlerRegistry registry) {
        registry.addHandler(handler, "/ws/realtime")
                .setHandshakeHandler(new RealtimeHandshakeHandler())
                .addInterceptors(new RealtimeTicketHandshakeInterceptor(tickets))
                .setAllowedOrigins(Arrays.stream(properties.getAllowedOrigins().split(","))
                        .map(String::trim).filter(origin -> !origin.isBlank()).toArray(String[]::new));
    }
}
