package com.guanlan.monitor.api;

import com.guanlan.monitor.service.SettingService;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/settings")
@RequiredArgsConstructor
public class SettingsController {
    private final SettingService settings;

    @GetMapping
    @PreAuthorize("hasRole('ADMIN')")
    SettingService.View get() { return settings.get(); }

    @PutMapping
    @PreAuthorize("hasRole('ADMIN')")
    SettingService.View update(@RequestBody SettingService.Update request) { return settings.update(request); }
}

