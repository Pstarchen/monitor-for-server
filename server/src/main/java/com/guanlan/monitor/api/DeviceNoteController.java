package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.DeviceNoteDtos;
import com.guanlan.monitor.service.DeviceAccessService;
import com.guanlan.monitor.service.DeviceNoteService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequiredArgsConstructor
public class DeviceNoteController {
    private final DeviceNoteService notes;
    private final DeviceAccessService access;

    @GetMapping("/api/devices/{deviceId}/notes")
    List<DeviceNoteDtos.View> list(@PathVariable String deviceId,
                                   @RequestParam(defaultValue = "50") int limit,
                                   Authentication authentication) {
        access.requireView(authentication, deviceId);
        return notes.list(deviceId, limit);
    }

    @PostMapping("/api/devices/{deviceId}/notes")
    @ResponseStatus(HttpStatus.CREATED)
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    DeviceNoteDtos.View create(@PathVariable String deviceId, @Valid @RequestBody DeviceNoteDtos.CreateRequest request, Authentication authentication) {
        access.requireManage(authentication, deviceId);
        return notes.create(deviceId, request);
    }

    @DeleteMapping("/api/devices/{deviceId}/notes/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    void delete(@PathVariable String deviceId, @PathVariable Long id, Authentication authentication) {
        access.requireManage(authentication, deviceId);
        notes.delete(deviceId, id);
    }

    @GetMapping("/api/device-notes/recent")
    List<DeviceNoteDtos.View> recent(@RequestParam(defaultValue = "8") int limit, Authentication authentication) {
        List<DeviceNoteDtos.View> result = notes.recent(limit);
        var visible = access.visibleDeviceIds(authentication);
        return visible == null ? result : result.stream().filter(note -> visible.contains(note.deviceId())).toList();
    }
}
