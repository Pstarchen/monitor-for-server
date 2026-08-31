package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.MaintenanceDtos;
import com.guanlan.monitor.security.ApiTokenPrincipal;
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

    @GetMapping
    List<MaintenanceDtos.WindowView> list(Authentication authentication) {
        List<MaintenanceDtos.WindowView> result = maintenance.list();
        if (authentication != null && authentication.getPrincipal() instanceof ApiTokenPrincipal principal && !principal.serverIds().isEmpty()) {
            result = result.stream().filter(window -> window.deviceId() == null || principal.serverIds().contains(window.deviceId())).toList();
        }
        return result;
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    MaintenanceDtos.WindowView create(Authentication authentication, @Valid @RequestBody MaintenanceDtos.WindowRequest request) {
        requireTarget(authentication, request.deviceId());
        return maintenance.create(request);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    MaintenanceDtos.WindowView update(Authentication authentication, @PathVariable Long id,
                                      @Valid @RequestBody MaintenanceDtos.WindowRequest request) {
        requireTarget(authentication, request.deviceId());
        return maintenance.update(id, request);
    }

    @DeleteMapping("/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    void delete(Authentication authentication, @PathVariable Long id) {
        requireTarget(authentication, maintenance.deviceId(id));
        maintenance.delete(id);
    }

    private void requireTarget(Authentication authentication, String deviceId) {
        if (authentication != null && authentication.getPrincipal() instanceof ApiTokenPrincipal principal
                && !principal.serverIds().isEmpty()
                && (deviceId == null || !principal.serverIds().contains(deviceId))) {
            throw new ApiException(HttpStatus.FORBIDDEN, "API Token 未获准管理该维护窗口");
        }
    }
}
