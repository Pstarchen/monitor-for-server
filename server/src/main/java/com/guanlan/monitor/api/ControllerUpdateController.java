package com.guanlan.monitor.api;

import com.fasterxml.jackson.databind.JsonNode;
import com.guanlan.monitor.service.AuditService;
import com.guanlan.monitor.service.ControllerUpdateService;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/admin/controller-update")
@PreAuthorize("hasRole('ADMIN')")
@RequiredArgsConstructor
public class ControllerUpdateController {
    private final ControllerUpdateService updates;
    private final AuditService audit;

    @GetMapping
    JsonNode status() {
        return updates.status();
    }

    @PostMapping("/check")
    JsonNode check() {
        JsonNode result = updates.check();
        audit.record("CONTROLLER_UPDATE_CHECK", "controller", "检查总控镜像更新");
        return result;
    }

    @PostMapping("/apply")
    JsonNode apply() {
        JsonNode result = updates.apply();
        audit.record("CONTROLLER_UPDATE_APPLY", "controller", "启动总控镜像更新");
        return result;
    }

    @PutMapping("/auto")
    JsonNode auto(@RequestBody AutoUpdateRequest request) {
        JsonNode result = updates.setAutoUpdate(request.enabled());
        audit.record("CONTROLLER_UPDATE_AUTO", "controller", request.enabled() ? "启用总控自动更新" : "关闭总控自动更新");
        return result;
    }

    record AutoUpdateRequest(boolean enabled) {}
}
