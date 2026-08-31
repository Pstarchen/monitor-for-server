package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.MaintenanceDtos;
import com.guanlan.monitor.service.DeviceAccessService;
import com.guanlan.monitor.service.MaintenanceWindowService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequiredArgsConstructor
@RequestMapping("/api/maintenance-windows")
public class MaintenanceController {
    private final MaintenanceWindowService maintenance;
    private final DeviceAccessService access;

    @GetMapping
    List<MaintenanceDtos.WindowView> list(Authentication authentication) {
        List<MaintenanceDtos.WindowView> result = maintenance.list();
        var visible = access.visibleDeviceIds(authentication);
        return visible == null ? result : result.stream()
                .filter(window -> window.scopeDeviceId() == null || visible.contains(window.scopeDeviceId())).toList();
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    MaintenanceDtos.WindowView create(Authentication authentication, @Valid @RequestBody MaintenanceDtos.WindowRequest request) {
        access.requireAlertScope(authentication, maintenance.deviceId(request));
        return maintenance.create(request);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    MaintenanceDtos.WindowView update(Authentication authentication, @PathVariable Long id,
                                      @Valid @RequestBody MaintenanceDtos.WindowRequest request) {
        access.requireAlertScope(authentication, maintenance.deviceId(id));
        access.requireAlertScope(authentication, maintenance.deviceId(request));
        return maintenance.update(id, request);
    }

    @DeleteMapping("/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    void delete(Authentication authentication, @PathVariable Long id) {
        access.requireAlertScope(authentication, maintenance.deviceId(id));
        maintenance.delete(id);
    }
}
