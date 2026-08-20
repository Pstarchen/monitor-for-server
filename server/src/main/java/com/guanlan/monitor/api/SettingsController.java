package com.guanlan.monitor.api;

import com.guanlan.monitor.service.SettingService;
import com.guanlan.monitor.service.NotificationService;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/settings")
@RequiredArgsConstructor
public class SettingsController {
    private final SettingService settings;
    private final NotificationService notifications;

    @GetMapping("/public")
    SettingService.PublicBrandView publicBrand() { return settings.publicBrand(); }

    @GetMapping
    @PreAuthorize("hasRole('ADMIN')")
    SettingService.View get() { return settings.get(); }

    @GetMapping("/agent-bootstrap")
    @PreAuthorize("hasAnyRole('ADMIN', 'OPERATOR')")
    SettingService.AgentBootstrapView agentBootstrap() { return settings.agentBootstrap(); }

    @PutMapping
    @PreAuthorize("hasRole('ADMIN')")
    SettingService.View update(@RequestBody SettingService.Update request) { return settings.update(request); }

    @PostMapping("/notifications/{channel}/test")
    @PreAuthorize("hasRole('ADMIN')")
    NotificationService.TestResult test(@PathVariable String channel) { return notifications.test(channel); }
}
