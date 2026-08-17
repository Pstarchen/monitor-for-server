package com.guanlan.monitor.api;

import com.guanlan.monitor.domain.AuditLog;
import com.guanlan.monitor.service.AuditService;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

@RestController
@RequestMapping("/api/admin/audit-logs")
@RequiredArgsConstructor
@PreAuthorize("hasRole('ADMIN')")
public class AuditController {
    private final AuditService audit;

    @GetMapping
    List<AuditLog> list(@RequestParam(defaultValue = "100") int limit) { return audit.recent(limit); }
}

