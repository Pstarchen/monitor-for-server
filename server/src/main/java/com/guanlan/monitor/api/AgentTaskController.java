package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.AgentTaskDtos;
import com.guanlan.monitor.service.AgentTaskService;
import com.guanlan.monitor.service.DeviceService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequiredArgsConstructor
public class AgentTaskController {
    private final AgentTaskService tasks;
    private final DeviceService devices;

    @GetMapping("/api/tasks")
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR','VIEWER')")
    List<AgentTaskDtos.View> list(Authentication authentication, @RequestParam(required = false) String deviceId,
                                  @RequestParam(defaultValue = "50") int limit) {
        return tasks.list(deviceId, limit, authentication);
    }

    @GetMapping("/api/tasks/{id}")
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR','VIEWER')")
    AgentTaskDtos.View get(Authentication authentication, @PathVariable Long id) {
        return tasks.get(id, authentication);
    }

    @PostMapping("/api/tasks")
    @ResponseStatus(HttpStatus.CREATED)
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    AgentTaskDtos.View create(Authentication authentication, @Valid @RequestBody AgentTaskDtos.CreateRequest request) {
        return tasks.create(request, authentication.getName(), authentication);
    }

    @PostMapping("/api/tasks/{id}/cancel")
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    AgentTaskDtos.View cancel(Authentication authentication, @PathVariable Long id) {
        tasks.cancel(id, authentication.getName(), authentication);
        return tasks.get(id, authentication);
    }

    @GetMapping("/api/agent/v1/tasks/next")
    ResponseEntity<AgentTaskDtos.Assignment> next(@RequestHeader("X-Device-Id") String deviceId,
                                                   @RequestHeader("X-Agent-Key") String agentKey) {
        devices.authenticateAgent(deviceId, agentKey);
        return tasks.claimNext(deviceId)
                .map(ResponseEntity::ok)
                .orElseGet(() -> ResponseEntity.noContent().build());
    }

    @PostMapping("/api/agent/v1/tasks/{id}/result")
    ResponseEntity<AgentTaskDtos.View> result(@RequestHeader("X-Device-Id") String deviceId,
                                               @RequestHeader("X-Agent-Key") String agentKey,
                                               @PathVariable Long id,
                                               @Valid @RequestBody AgentTaskDtos.ResultRequest request) {
        devices.authenticateAgent(deviceId, agentKey);
        return ResponseEntity.ok(tasks.complete(deviceId, id, request));
    }
}
