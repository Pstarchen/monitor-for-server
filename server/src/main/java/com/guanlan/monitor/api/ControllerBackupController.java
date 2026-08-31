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
@RequestMapping("/api/admin/controller-backups")
@PreAuthorize("hasRole('ADMIN')")
@RequiredArgsConstructor
public class ControllerBackupController {
    private final ControllerUpdateService backups;
    private final AuditService audit;

    @GetMapping
    JsonNode status() {
        return backups.backupStatus();
    }

    @PostMapping
    JsonNode create() {
        JsonNode result = backups.createBackup();
        audit.record("CONTROLLER_BACKUP_CREATE", "controller", "创建总控数据库备份");
        return result;
    }

    @PostMapping("/restore")
    JsonNode restore(@RequestBody RestoreRequest request) {
        if (request == null || request.name() == null || request.name().isBlank()) {
            throw new ApiException(org.springframework.http.HttpStatus.BAD_REQUEST, "备份文件名不能为空");
        }
        JsonNode result = backups.restoreBackup(request.name());
        audit.record("CONTROLLER_BACKUP_RESTORE", "controller", "恢复总控数据库备份 " + request.name().trim());
        return result;
    }

    @PutMapping("/auto")
    JsonNode auto(@RequestBody AutoRequest request) {
        if (request == null || request.retention() < 1 || request.retention() > 100) {
            throw new ApiException(org.springframework.http.HttpStatus.BAD_REQUEST, "备份保留数量必须在 1-100 之间");
        }
        JsonNode result = backups.setBackupAuto(request.enabled(), request.retention());
        audit.record("CONTROLLER_BACKUP_AUTO", "controller", request.enabled() ? "启用每日数据库备份" : "关闭每日数据库备份");
        return result;
    }

    record RestoreRequest(String name) {}
    record AutoRequest(boolean enabled, int retention) {}
}
