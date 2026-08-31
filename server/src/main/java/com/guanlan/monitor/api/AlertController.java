package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.AlertDtos;
import com.guanlan.monitor.service.AlertService;
import com.guanlan.monitor.service.DeviceAccessService;
import com.guanlan.monitor.domain.AlertEvent;
import com.guanlan.monitor.domain.AlertRule;
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
    private final DeviceAccessService access;

    @GetMapping("/api/alerts")
    List<AlertDtos.EventView> events(@RequestParam(defaultValue = "100") int limit,
                                     @RequestParam(required = false) AlertEvent.Status status,
                                     @RequestParam(required = false) AlertRule.Severity severity,
                                     @RequestParam(required = false) String deviceId,
                                     Authentication authentication) {
        if (deviceId != null && !deviceId.isBlank()) access.requireView(authentication, deviceId);
        List<AlertDtos.EventView> result = alerts.listEvents(500, status, severity, deviceId);
        var visible = access.visibleDeviceIds(authentication);
        if (visible != null) result = result.stream().filter(event -> visible.contains(event.deviceId())).toList();
        return result.stream().limit(Math.min(Math.max(limit, 1), 500)).toList();
    }

    @PostMapping("/api/alerts/acknowledge")
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    List<AlertDtos.EventView> acknowledgeMany(@Valid @RequestBody AlertDtos.AcknowledgeRequest request,
                                               Authentication authentication) {
        requireAlertAccess(authentication, request.ids());
        return alerts.acknowledge(request.ids(), authentication.getName());
    }

    @PostMapping("/api/alerts/{id}/acknowledge")
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    AlertDtos.EventView acknowledge(@PathVariable Long id, Authentication authentication) {
        requireAlertAccess(authentication, List.of(id));
        return alerts.acknowledge(id, authentication.getName());
    }

    private void requireAlertAccess(Authentication authentication, List<Long> ids) {
        for (Long id : ids) {
            access.requireAlert(authentication, alerts.deviceId(id));
        }
    }

    @GetMapping("/api/alert-rules")
    List<AlertDtos.RuleView> rules(Authentication authentication) {
        List<AlertDtos.RuleView> result = alerts.listRules();
        var visible = access.visibleDeviceIds(authentication);
        return visible == null ? result : result.stream()
                .filter(rule -> rule.deviceId() == null || visible.contains(rule.deviceId())).toList();
    }

    @PostMapping("/api/alert-rules")
    @ResponseStatus(HttpStatus.CREATED)
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    AlertDtos.RuleView create(Authentication authentication, @Valid @RequestBody AlertDtos.RuleRequest request) {
        access.requireAlertScope(authentication, request.deviceId());
        return alerts.createRule(request);
    }

    @PutMapping("/api/alert-rules/{id}")
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    AlertDtos.RuleView update(Authentication authentication, @PathVariable Long id, @Valid @RequestBody AlertDtos.RuleRequest request) {
        access.requireAlertScope(authentication, alerts.ruleDeviceId(id));
        access.requireAlertScope(authentication, request.deviceId());
        return alerts.updateRule(id, request);
    }

    @DeleteMapping("/api/alert-rules/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    void delete(Authentication authentication, @PathVariable Long id) {
        access.requireAlertScope(authentication, alerts.ruleDeviceId(id));
        alerts.deleteRule(id);
    }
}
