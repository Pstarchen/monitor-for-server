package com.guanlan.monitor.api;

import com.guanlan.monitor.realtime.RealtimeOutboxService;
import com.guanlan.monitor.realtime.RealtimeTicketService;
import lombok.RequiredArgsConstructor;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/realtime")
@RequiredArgsConstructor
public class RealtimeController {
    private final RealtimeTicketService tickets;
    private final RealtimeOutboxService outbox;

    @PostMapping({"/tickets", "/ticket"})
    RealtimeTicketService.IssuedTicket issue(Authentication authentication,
                                             @RequestParam(required = false) String afterEventId) {
        return tickets.issue(authentication, afterEventId);
    }

    @GetMapping("/events")
    RealtimeOutboxService.ReplayPage replay(Authentication authentication,
                                            @RequestParam(required = false) String afterEventId,
                                            @RequestParam(defaultValue = "200") int limit) {
        return outbox.replay(authentication, afterEventId, limit);
    }
}
