package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.MobileDiagnosticsDtos;
import com.guanlan.monitor.service.DeviceAccessService;
import com.guanlan.monitor.service.MobileDiagnosticsService;
import lombok.RequiredArgsConstructor;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/v2/devices/{deviceId}")
@RequiredArgsConstructor
public class MobileDiagnosticsController {
    private final MobileDiagnosticsService diagnostics;
    private final DeviceAccessService access;

    @GetMapping("/diagnostics")
    MobileDiagnosticsDtos.Diagnostics diagnostics(Authentication authentication, @PathVariable String deviceId) {
        access.requireView(authentication, deviceId);
        return diagnostics.diagnostics(deviceId);
    }

    @GetMapping("/metrics/history")
    MobileDiagnosticsDtos.History history(Authentication authentication, @PathVariable String deviceId,
                                           @RequestParam(defaultValue = "6H") String range) {
        access.requireView(authentication, deviceId);
        return diagnostics.history(deviceId, range);
    }
}
