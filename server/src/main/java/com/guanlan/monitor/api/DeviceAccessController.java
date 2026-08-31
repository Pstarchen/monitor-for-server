package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.UserDtos;
import com.guanlan.monitor.service.DeviceAccessService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequiredArgsConstructor
public class DeviceAccessController {
    private final DeviceAccessService access;

    @GetMapping("/api/device-access/me")
    List<UserDtos.DevicePermissionView> current(Authentication authentication) {
        return access.current(authentication);
    }

    @GetMapping("/api/admin/users/{id}/device-permissions")
    @PreAuthorize("hasRole('ADMIN')")
    List<UserDtos.DevicePermissionView> list(@PathVariable Long id) {
        return access.listForUser(id);
    }

    @PutMapping("/api/admin/users/{id}/device-permissions")
    @PreAuthorize("hasRole('ADMIN')")
    List<UserDtos.DevicePermissionView> replace(@PathVariable Long id,
                                                @Valid @RequestBody UserDtos.DevicePermissionRequest request) {
        return access.replace(id, request);
    }
}
