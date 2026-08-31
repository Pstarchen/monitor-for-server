package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.DeviceStatusDtos;
import com.guanlan.monitor.service.DeviceAccessService;
import com.guanlan.monitor.service.DeviceStatusHistoryService;
import lombok.RequiredArgsConstructor;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.Instant;
import java.util.List;

@RestController
@RequestMapping("/api/devices/{deviceId}/status-history")
@RequiredArgsConstructor
public class DeviceStatusController {
    private final DeviceStatusHistoryService history;
    private final DeviceAccessService access;

    @GetMapping
    List<DeviceStatusDtos.View> list(@org.springframework.web.bind.annotation.PathVariable String deviceId,
                                     @RequestParam(required = false) Instant from,
                                     @RequestParam(required = false) Instant to,
                                     @RequestParam(defaultValue = "100") int limit,
                                     Authentication authentication) {
        access.requireView(authentication, deviceId);
        return history.list(deviceId, from, to, limit);
    }
}
