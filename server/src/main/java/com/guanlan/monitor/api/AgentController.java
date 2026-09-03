package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.AgentReportRequest;
import com.guanlan.monitor.api.dto.DeviceDtos;
import com.guanlan.monitor.api.dto.MetricView;
import com.guanlan.monitor.service.MetricService;
import com.guanlan.monitor.service.SettingService;
import com.guanlan.monitor.service.DdnsService;
import com.guanlan.monitor.service.DeviceService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.http.CacheControl;
import org.springframework.web.bind.annotation.*;

import java.net.InetAddress;
import java.net.UnknownHostException;

@RestController
@RequestMapping("/api/agent/v1")
@RequiredArgsConstructor
public class AgentController {
    private final MetricService metrics;
    private final SettingService settings;
    private final DdnsService ddns;
    private final DeviceService devices;

    @PostMapping("/enroll")
    ResponseEntity<DeviceDtos.EnrollmentCredential> enroll(@Valid @RequestBody DeviceDtos.EnrollmentRequest request) {
        return ResponseEntity.ok()
                .cacheControl(CacheControl.noStore())
                .body(devices.enroll(request));
    }

    @PostMapping("/reports")
    ResponseEntity<MetricView> report(
            @RequestHeader("X-Device-Id") String deviceId,
            @RequestHeader("X-Agent-Key") String agentKey,
            jakarta.servlet.http.HttpServletRequest httpRequest,
            @Valid @RequestBody AgentReportRequest report
    ) {
        MetricService.IngestResult result = metrics.ingest(deviceId, agentKey, report);
        if (result.live()) ddns.updateForDevice(devices.require(deviceId), clientIp(httpRequest));
        return ResponseEntity.accepted()
                .header("X-Agent-Interval-Seconds", Integer.toString(settings.agentCollectionSeconds()))
                .body(result.metric());
    }

    private String clientIp(jakarta.servlet.http.HttpServletRequest request) {
        String forwarded = request.getHeader("X-Real-IP");
        if (isTrustedProxy(request.getRemoteAddr()) && forwarded != null && !forwarded.isBlank()) return forwarded.trim();
        String remote = request.getRemoteAddr();
        return remote == null ? "" : remote.trim();
    }

    private boolean isTrustedProxy(String value) {
        if (value == null || value.isBlank()) return false;
        try {
            InetAddress address = InetAddress.getByName(value.trim());
            return address.isLoopbackAddress() || address.isSiteLocalAddress() || address.isLinkLocalAddress();
        } catch (UnknownHostException ignored) {
            return false;
        }
    }

}
