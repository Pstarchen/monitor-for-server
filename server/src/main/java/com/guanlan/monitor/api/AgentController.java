package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.AgentReportRequest;
import com.guanlan.monitor.api.dto.MetricView;
import com.guanlan.monitor.service.MetricService;
import com.guanlan.monitor.service.SettingService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/agent/v1")
@RequiredArgsConstructor
public class AgentController {
    private final MetricService metrics;
    private final SettingService settings;

    @PostMapping("/reports")
    ResponseEntity<MetricView> report(
            @RequestHeader("X-Device-Id") String deviceId,
            @RequestHeader("X-Agent-Key") String agentKey,
            @Valid @RequestBody AgentReportRequest report
    ) {
        MetricView view = metrics.ingest(deviceId, agentKey, report);
        return ResponseEntity.accepted()
                .header("X-Agent-Interval-Seconds", Integer.toString(settings.agentCollectionSeconds()))
                .body(view);
    }
}
