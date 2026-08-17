package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.MetricView;
import com.guanlan.monitor.service.MetricService;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.*;

import java.time.Instant;
import java.util.List;

@RestController
@RequestMapping("/api/devices/{deviceId}/metrics")
@RequiredArgsConstructor
public class MetricController {
    private final MetricService metrics;

    @GetMapping("/latest")
    MetricView latest(@PathVariable String deviceId) { return metrics.latest(deviceId); }

    @GetMapping("/history")
    List<MetricView> history(@PathVariable String deviceId, @RequestParam Instant from, @RequestParam Instant to) {
        return metrics.history(deviceId, from, to);
    }
}

