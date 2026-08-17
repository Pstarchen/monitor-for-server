package com.guanlan.monitor.service;

import com.guanlan.monitor.domain.AuditLog;
import com.guanlan.monitor.repository.AuditLogRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.PageRequest;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;

import java.util.List;

@Service
@RequiredArgsConstructor
public class AuditService {
    private final AuditLogRepository logs;

    public void record(String action, String target, String summary) {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        String actor = auth == null || !auth.isAuthenticated() ? "system" : auth.getName();
        AuditLog log = new AuditLog();
        log.setActor(actor);
        log.setAction(action);
        log.setTarget(target);
        log.setSummary(summary);
        logs.save(log);
    }

    public List<AuditLog> recent(int limit) {
        return logs.findAllByOrderByCreatedAtDesc(PageRequest.of(0, Math.min(Math.max(limit, 1), 200)));
    }
}

