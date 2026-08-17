package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.AlertDtos;
import com.guanlan.monitor.service.AlertService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequiredArgsConstructor
public class AlertController {
    private final AlertService alerts;

    @GetMapping("/api/alerts")
    List<AlertDtos.EventView> events(@RequestParam(defaultValue = "100") int limit) { return alerts.listEvents(limit); }

    @PostMapping("/api/alerts/{id}/acknowledge")
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    AlertDtos.EventView acknowledge(@PathVariable Long id, Authentication authentication) {
        return alerts.acknowledge(id, authentication.getName());
    }

    @GetMapping("/api/alert-rules")
    List<AlertDtos.RuleView> rules() { return alerts.listRules(); }

    @PostMapping("/api/alert-rules")
    @ResponseStatus(HttpStatus.CREATED)
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    AlertDtos.RuleView create(@Valid @RequestBody AlertDtos.RuleRequest request) { return alerts.createRule(request); }

    @PutMapping("/api/alert-rules/{id}")
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    AlertDtos.RuleView update(@PathVariable Long id, @Valid @RequestBody AlertDtos.RuleRequest request) { return alerts.updateRule(id, request); }

    @DeleteMapping("/api/alert-rules/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    void delete(@PathVariable Long id) { alerts.deleteRule(id); }
}

