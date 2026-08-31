package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.DeviceDtos;
import com.guanlan.monitor.api.dto.DeviceHealthDtos;
import com.guanlan.monitor.service.DeviceService;
import com.guanlan.monitor.service.DeviceAccessService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/devices")
@RequiredArgsConstructor
public class DeviceController {
    private final DeviceService devices;
    private final DeviceAccessService access;

    @GetMapping
    List<DeviceDtos.View> list(Authentication authentication) {
        List<DeviceDtos.View> result = devices.list();
        var visible = access.visibleDeviceIds(authentication);
        return visible == null ? result : result.stream().filter(device -> visible.contains(device.id())).toList();
    }

    @GetMapping("/{id}")
    DeviceDtos.View get(Authentication authentication, @PathVariable String id) {
        access.requireView(authentication, id);
        return devices.get(id);
    }

    @GetMapping("/{id}/health")
    DeviceHealthDtos.View health(Authentication authentication, @PathVariable String id) {
        access.requireView(authentication, id);
        return devices.health(id);
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    DeviceDtos.Credential create(Authentication authentication, @Valid @RequestBody DeviceDtos.CreateRequest request) {
        if (authentication != null && authentication.getPrincipal() instanceof com.guanlan.monitor.security.ApiTokenPrincipal principal && !principal.serverIds().isEmpty()) {
            throw new com.guanlan.monitor.api.ApiException(HttpStatus.FORBIDDEN, "带服务器白名单的 API Token 不能创建设备");
        }
        return devices.create(request, authentication);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    DeviceDtos.View update(Authentication authentication, @PathVariable String id, @Valid @RequestBody DeviceDtos.UpdateRequest request) {
        access.requireManage(authentication, id);
        return devices.update(id, request);
    }

    @PostMapping("/{id}/rotate-key")
    @PreAuthorize("hasRole('ADMIN')")
    DeviceDtos.Credential rotateKey(Authentication authentication, @PathVariable String id) {
        access.requireManage(authentication, id);
        return devices.regenerateKey(id);
    }

    @DeleteMapping("/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    @PreAuthorize("hasRole('ADMIN')")
    void delete(Authentication authentication, @PathVariable String id) {
        access.requireManage(authentication, id);
        devices.delete(id);
    }
}
