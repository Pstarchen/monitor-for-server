package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.AgentReportRequest;
import com.guanlan.monitor.api.dto.MetricView;
import com.guanlan.monitor.service.MetricService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/agent/v1")
@RequiredArgsConstructor
public class AgentController {
    private final MetricService metrics;

    @PostMapping("/reports")
    ResponseEntity<MetricView> report(
            @RequestHeader("X-Device-Id") String deviceId,
            @RequestHeader("X-Agent-Key") String agentKey,
            @Valid @RequestBody AgentReportRequest report
    ) {
        return ResponseEntity.accepted().body(metrics.ingest(deviceId, agentKey, report));
    }
}

