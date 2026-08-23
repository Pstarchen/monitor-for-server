package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.DeviceDtos;
import com.guanlan.monitor.service.DeviceService;
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

    @GetMapping
    List<DeviceDtos.View> list(Authentication authentication) {
        List<DeviceDtos.View> result = devices.list();
        if (authentication != null && authentication.getPrincipal() instanceof com.guanlan.monitor.security.ApiTokenPrincipal principal && !principal.serverIds().isEmpty()) {
            return result.stream().filter(device -> principal.serverIds().contains(device.id())).toList();
        }
        return result;
    }

    @GetMapping("/{id}")
    DeviceDtos.View get(@PathVariable String id) { return devices.get(id); }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    DeviceDtos.Credential create(Authentication authentication, @Valid @RequestBody DeviceDtos.CreateRequest request) {
        if (authentication != null && authentication.getPrincipal() instanceof com.guanlan.monitor.security.ApiTokenPrincipal principal && !principal.serverIds().isEmpty()) {
            throw new com.guanlan.monitor.api.ApiException(HttpStatus.FORBIDDEN, "带服务器白名单的 API Token 不能创建设备");
        }
        return devices.create(request);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    DeviceDtos.View update(@PathVariable String id, @Valid @RequestBody DeviceDtos.UpdateRequest request) { return devices.update(id, request); }

    @PostMapping("/{id}/rotate-key")
    @PreAuthorize("hasRole('ADMIN')")
    DeviceDtos.Credential rotateKey(@PathVariable String id) { return devices.regenerateKey(id); }

    @DeleteMapping("/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    @PreAuthorize("hasRole('ADMIN')")
    void delete(@PathVariable String id) { devices.delete(id); }
}
