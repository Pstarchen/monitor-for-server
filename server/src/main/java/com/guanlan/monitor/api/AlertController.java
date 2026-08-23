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
    List<AlertDtos.EventView> events(@RequestParam(defaultValue = "100") int limit, Authentication authentication) {
        List<AlertDtos.EventView> result = alerts.listEvents(Math.max(limit, 500));
        if (authentication != null && authentication.getPrincipal() instanceof com.guanlan.monitor.security.ApiTokenPrincipal principal && !principal.serverIds().isEmpty()) {
            result = result.stream().filter(event -> principal.serverIds().contains(event.deviceId())).toList();
        }
        return result.stream().limit(Math.min(Math.max(limit, 1), 500)).toList();
    }

    @PostMapping("/api/alerts/{id}/acknowledge")
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    AlertDtos.EventView acknowledge(@PathVariable Long id, Authentication authentication) {
        if (authentication != null && authentication.getPrincipal() instanceof com.guanlan.monitor.security.ApiTokenPrincipal principal && !principal.serverIds().isEmpty()
                && !principal.serverIds().contains(alerts.deviceId(id))) {
            throw new ApiException(org.springframework.http.HttpStatus.FORBIDDEN, "API Token 未获准访问该服务器");
        }
        return alerts.acknowledge(id, authentication.getName());
    }

    @GetMapping("/api/alert-rules")
    List<AlertDtos.RuleView> rules(Authentication authentication) {
        List<AlertDtos.RuleView> result = alerts.listRules();
        if (authentication != null && authentication.getPrincipal() instanceof com.guanlan.monitor.security.ApiTokenPrincipal principal && !principal.serverIds().isEmpty()) {
            result = result.stream().filter(rule -> rule.deviceId() == null || principal.serverIds().contains(rule.deviceId())).toList();
        }
        return result;
    }

    @PostMapping("/api/alert-rules")
    @ResponseStatus(HttpStatus.CREATED)
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    AlertDtos.RuleView create(Authentication authentication, @Valid @RequestBody AlertDtos.RuleRequest request) {
        requireRuleTarget(authentication, request.deviceId());
        return alerts.createRule(request);
    }

    @PutMapping("/api/alert-rules/{id}")
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    AlertDtos.RuleView update(Authentication authentication, @PathVariable Long id, @Valid @RequestBody AlertDtos.RuleRequest request) {
        requireRuleTarget(authentication, request.deviceId());
        return alerts.updateRule(id, request);
    }

    @DeleteMapping("/api/alert-rules/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    void delete(Authentication authentication, @PathVariable Long id) {
        requireRuleTarget(authentication, alerts.ruleDeviceId(id));
        alerts.deleteRule(id);
    }

    private void requireRuleTarget(Authentication authentication, String deviceId) {
        if (authentication != null && authentication.getPrincipal() instanceof com.guanlan.monitor.security.ApiTokenPrincipal principal
                && !principal.serverIds().isEmpty()
                && (deviceId == null || !principal.serverIds().contains(deviceId))) {
            throw new ApiException(org.springframework.http.HttpStatus.FORBIDDEN, "API Token 未获准访问该服务器规则");
        }
    }
}
