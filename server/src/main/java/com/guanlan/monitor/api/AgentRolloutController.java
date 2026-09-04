package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.AgentRolloutDtos;
import com.guanlan.monitor.service.AgentRolloutService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequiredArgsConstructor
@RequestMapping("/api/agent-rollouts")
public class AgentRolloutController {
    private final AgentRolloutService rollouts;

    @GetMapping
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR','VIEWER')")
    List<AgentRolloutDtos.View> list(Authentication authentication,
                                     @RequestParam(defaultValue = "50") int limit) {
        return rollouts.list(limit, authentication);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR','VIEWER')")
    AgentRolloutDtos.View get(Authentication authentication, @PathVariable Long id) {
        return rollouts.get(id, authentication);
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    @PreAuthorize("hasRole('ADMIN')")
    AgentRolloutDtos.View create(Authentication authentication,
                                  @Valid @RequestBody AgentRolloutDtos.CreateRequest request) {
        return rollouts.create(request, authentication.getName());
    }

    @PostMapping("/{id}/start")
    @PreAuthorize("hasRole('ADMIN')")
    AgentRolloutDtos.View start(@PathVariable Long id,
                                 @Valid @RequestBody(required = false) AgentRolloutDtos.ActionRequest request) {
        return rollouts.start(id, reason(request));
    }

    @PostMapping("/{id}/pause")
    @PreAuthorize("hasRole('ADMIN')")
    AgentRolloutDtos.View pause(@PathVariable Long id,
                                 @Valid @RequestBody(required = false) AgentRolloutDtos.ActionRequest request) {
        return rollouts.pause(id, reason(request));
    }

    @PostMapping("/{id}/resume")
    @PreAuthorize("hasRole('ADMIN')")
    AgentRolloutDtos.View resume(@PathVariable Long id,
                                  @Valid @RequestBody(required = false) AgentRolloutDtos.ActionRequest request) {
        return rollouts.resume(id, reason(request));
    }

    @PostMapping("/{id}/cancel")
    @PreAuthorize("hasRole('ADMIN')")
    AgentRolloutDtos.View cancel(@PathVariable Long id,
                                  @Valid @RequestBody(required = false) AgentRolloutDtos.ActionRequest request) {
        return rollouts.cancel(id, reason(request));
    }

    @PostMapping("/{id}/rollback")
    @PreAuthorize("hasRole('ADMIN')")
    AgentRolloutDtos.View rollback(@PathVariable Long id,
                                    @Valid @RequestBody(required = false) AgentRolloutDtos.ActionRequest request) {
        return rollouts.rollback(id, reason(request));
    }

    private String reason(AgentRolloutDtos.ActionRequest request) {
        return request == null ? null : request.reason();
    }
}
