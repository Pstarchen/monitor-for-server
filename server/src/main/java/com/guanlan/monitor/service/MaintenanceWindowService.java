package com.guanlan.monitor.service;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.api.dto.MaintenanceDtos;
import com.guanlan.monitor.domain.AlertRule;
import com.guanlan.monitor.domain.Device;
import com.guanlan.monitor.domain.MaintenanceWindow;
import com.guanlan.monitor.repository.AlertRuleRepository;
import com.guanlan.monitor.repository.MaintenanceWindowRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.*;
import java.time.temporal.TemporalAdjusters;
import java.util.List;

@Service
@RequiredArgsConstructor
public class MaintenanceWindowService {
    private static final Duration MAX_ONCE_DURATION = Duration.ofDays(90);
    private final MaintenanceWindowRepository windows;
    private final AlertRuleRepository rules;
    private final DeviceService devices;
    private final AuditService audit;

    @Transactional(readOnly = true)
    public List<MaintenanceDtos.WindowView> list() {
        Instant now = Instant.now();
        return windows.findAllByOrderByStartsAtDesc().stream().map(window -> view(window, now)).toList();
    }

    @Transactional(readOnly = true)
    public String deviceId(Long id) {
        MaintenanceWindow window = require(id);
        return window.getDevice() == null ? null : window.getDevice().getId();
    }

    @Transactional
    public MaintenanceDtos.WindowView create(MaintenanceDtos.WindowRequest request) {
        validate(request);
        MaintenanceWindow window = new MaintenanceWindow();
        apply(window, request);
        windows.save(window);
        audit.record("MAINTENANCE_CREATE", "maintenance:" + window.getId(), "创建维护窗口 " + window.getName());
        return view(window, Instant.now());
    }

    @Transactional
    public MaintenanceDtos.WindowView update(Long id, MaintenanceDtos.WindowRequest request) {
        validate(request);
        MaintenanceWindow window = require(id);
        apply(window, request);
        audit.record("MAINTENANCE_UPDATE", "maintenance:" + id, "更新维护窗口 " + window.getName());
        return view(window, Instant.now());
    }

    @Transactional
    public void delete(Long id) {
        MaintenanceWindow window = require(id);
        windows.delete(window);
        audit.record("MAINTENANCE_DELETE", "maintenance:" + id, "删除维护窗口 " + window.getName());
    }

    @Transactional(readOnly = true)
    public boolean isMuted(Device device, AlertRule rule, Instant now) {
        return windows.findByEnabledTrue().stream()
                .filter(window -> window.getDevice() == null || window.getDevice().getId().equals(device.getId()))
                .filter(window -> window.getRule() == null || window.getRule().getId().equals(rule.getId()))
                .anyMatch(window -> isActive(window, now));
    }

    boolean isActive(MaintenanceWindow window, Instant now) {
        if (!window.isEnabled() || now.isBefore(window.getStartsAt())) return false;
        if (window.getRepeatUntil() != null && now.isAfter(window.getRepeatUntil())) return false;
        if (window.getRecurrence() == MaintenanceWindow.Recurrence.NONE) {
            return !now.isBefore(window.getStartsAt()) && now.isBefore(window.getEndsAt());
        }

        ZoneId zone = ZoneId.of(window.getTimezone());
        ZonedDateTime baseStart = window.getStartsAt().atZone(zone);
        Duration duration = Duration.between(window.getStartsAt(), window.getEndsAt());
        ZonedDateTime localNow = now.atZone(zone);
        ZonedDateTime candidate;
        if (window.getRecurrence() == MaintenanceWindow.Recurrence.DAILY) {
            candidate = localNow.toLocalDate().atTime(baseStart.toLocalTime()).atZone(zone);
        } else {
            LocalDate date = localNow.toLocalDate().with(TemporalAdjusters.previousOrSame(baseStart.getDayOfWeek()));
            candidate = date.atTime(baseStart.toLocalTime()).atZone(zone);
        }
        if (now.isBefore(candidate.toInstant())) {
            candidate = window.getRecurrence() == MaintenanceWindow.Recurrence.DAILY
                    ? candidate.minusDays(1) : candidate.minusWeeks(1);
        }
        Instant candidateStart = candidate.toInstant();
        return !candidateStart.isBefore(window.getStartsAt())
                && !now.isBefore(candidateStart)
                && now.isBefore(candidate.plus(duration).toInstant());
    }

    private void validate(MaintenanceDtos.WindowRequest request) {
        if (!request.endsAt().isAfter(request.startsAt())) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "维护窗口结束时间必须晚于开始时间");
        }
        Duration duration = Duration.between(request.startsAt(), request.endsAt());
        Duration maximum = switch (request.recurrence()) {
            case NONE -> MAX_ONCE_DURATION;
            case DAILY -> Duration.ofDays(1);
            case WEEKLY -> Duration.ofDays(7);
        };
        if (duration.compareTo(maximum) > 0) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "维护窗口持续时间超过重复周期");
        }
        try {
            ZoneId.of(request.timezone().trim());
        } catch (DateTimeException exception) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "维护窗口时区无效");
        }
        if (request.repeatUntil() != null && !request.repeatUntil().isAfter(request.startsAt())) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "重复结束时间必须晚于开始时间");
        }
        AlertRule rule = request.ruleId() == null ? null : rules.findById(request.ruleId())
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "告警规则不存在"));
        if (rule != null && request.deviceId() != null && !request.deviceId().isBlank()
                && rule.getDevice() != null && !rule.getDevice().getId().equals(request.deviceId())) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "维护窗口设备与告警规则范围不一致");
        }
    }

    private void apply(MaintenanceWindow window, MaintenanceDtos.WindowRequest request) {
        window.setName(request.name().trim());
        window.setDevice(request.deviceId() == null || request.deviceId().isBlank() ? null : devices.require(request.deviceId()));
        window.setRule(request.ruleId() == null ? null : rules.findById(request.ruleId())
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "告警规则不存在")));
        window.setStartsAt(request.startsAt());
        window.setEndsAt(request.endsAt());
        window.setTimezone(request.timezone().trim());
        window.setRecurrence(request.recurrence());
        window.setRepeatUntil(request.recurrence() == MaintenanceWindow.Recurrence.NONE ? null : request.repeatUntil());
        window.setReason(request.reason() == null || request.reason().isBlank() ? null : request.reason().trim());
        window.setEnabled(request.enabled());
    }

    private MaintenanceWindow require(Long id) {
        return windows.findById(id).orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "维护窗口不存在"));
    }

    private MaintenanceDtos.WindowView view(MaintenanceWindow window, Instant now) {
        return new MaintenanceDtos.WindowView(
                window.getId(), window.getName(),
                window.getDevice() == null ? null : window.getDevice().getId(),
                window.getDevice() == null ? null : window.getDevice().getName(),
                window.getRule() == null ? null : window.getRule().getId(),
                window.getRule() == null ? null : window.getRule().getName(),
                window.getStartsAt(), window.getEndsAt(), window.getTimezone(), window.getRecurrence(),
                window.getRepeatUntil(), window.getReason(), window.isEnabled(), isActive(window, now), window.getUpdatedAt());
    }
}
