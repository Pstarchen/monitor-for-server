package com.guanlan.monitor.realtime;

import com.guanlan.monitor.api.ApiException;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.http.server.ServerHttpRequest;
import org.springframework.http.server.ServerHttpResponse;
import org.springframework.web.socket.WebSocketHandler;
import org.springframework.web.socket.server.support.HttpSessionHandshakeInterceptor;
import org.springframework.web.util.UriComponentsBuilder;

import java.util.Map;

@RequiredArgsConstructor
public class RealtimeTicketHandshakeInterceptor extends HttpSessionHandshakeInterceptor {
    public static final String AFTER_EVENT_ID = "realtime.afterEventId";
    private final RealtimeTicketService tickets;

    @Override
    public boolean beforeHandshake(ServerHttpRequest request, ServerHttpResponse response,
                                   WebSocketHandler wsHandler, Map<String, Object> attributes) {
        String ticket = UriComponentsBuilder.fromUri(request.getURI()).build()
                .getQueryParams().getFirst("ticket");
        try {
            RealtimeTicketService.ConsumedTicket consumed = tickets.consume(ticket);
            attributes.put(AFTER_EVENT_ID, consumed.afterEventId());
            attributes.put("realtime.authentication", consumed.authentication());
            return true;
        } catch (ApiException exception) {
            response.setStatusCode(exception.getStatus());
            return false;
        } catch (Exception exception) {
            response.setStatusCode(HttpStatus.UNAUTHORIZED);
            return false;
        }
    }
}
