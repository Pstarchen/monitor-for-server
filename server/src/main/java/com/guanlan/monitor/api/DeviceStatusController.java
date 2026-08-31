package com.guanlan.monitor.api;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.api.dto.DeviceStatusDtos;
import com.guanlan.monitor.security.ApiTokenPrincipal;
import com.guanlan.monitor.service.DeviceStatusHistoryService;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
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

    @GetMapping
    List<DeviceStatusDtos.View> list(@org.springframework.web.bind.annotation.PathVariable String deviceId,
                                     @RequestParam(required = false) Instant from,
                                     @RequestParam(required = false) Instant to,
                                     @RequestParam(defaultValue = "100") int limit,
                                     Authentication authentication) {
        if (authentication != null && authentication.getPrincipal() instanceof ApiTokenPrincipal principal
                && !principal.serverIds().isEmpty() && !principal.serverIds().contains(deviceId)) {
            throw new ApiException(HttpStatus.FORBIDDEN, "API Token 未获准访问该服务器");
        }
        return history.list(deviceId, from, to, limit);
    }
}
