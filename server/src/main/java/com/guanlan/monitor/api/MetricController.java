package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.MetricView;
import com.guanlan.monitor.service.MetricService;
import com.guanlan.monitor.service.DeviceAccessService;
import lombok.RequiredArgsConstructor;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.*;

import java.time.Instant;
import java.util.List;

@RestController
@RequestMapping("/api/devices/{deviceId}/metrics")
@RequiredArgsConstructor
public class MetricController {
    private final MetricService metrics;
    private final DeviceAccessService access;

    @GetMapping("/latest")
    MetricView latest(Authentication authentication, @PathVariable String deviceId) {
        access.requireView(authentication, deviceId);
        return metrics.latest(deviceId);
    }

    @GetMapping("/history")
    List<MetricView> history(Authentication authentication, @PathVariable String deviceId, @RequestParam Instant from, @RequestParam Instant to) {
        access.requireView(authentication, deviceId);
        return metrics.history(deviceId, from, to);
    }
}

