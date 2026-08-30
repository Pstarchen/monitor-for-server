package com.guanlan.monitor.api;

import com.guanlan.monitor.service.ServiceMonitorService;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.time.Instant;

@RestController
@RequestMapping("/api/heartbeat")
@RequiredArgsConstructor
public class HeartbeatController {
    private final ServiceMonitorService services;

    @RequestMapping(value = "/{id}", method = {RequestMethod.GET, RequestMethod.POST})
    ResponseEntity<Ack> receive(@PathVariable Long id,
                                @RequestHeader(value = "X-Heartbeat-Token", required = false) String headerToken,
                                @RequestParam(value = "token", required = false) String queryToken) {
        String token = headerToken == null || headerToken.isBlank() ? queryToken : headerToken;
        Instant acceptedAt = services.receiveHeartbeat(id, token);
        return ResponseEntity.accepted().body(new Ack("accepted", acceptedAt));
    }

    public record Ack(String status, Instant acceptedAt) {}
}
