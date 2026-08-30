package com.guanlan.monitor.service;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.api.dto.AlertDtos;
import com.guanlan.monitor.domain.AlertEvent;
import com.guanlan.monitor.domain.AlertRule;
import com.guanlan.monitor.domain.Device;
import com.guanlan.monitor.domain.MetricSnapshot;
import com.guanlan.monitor.realtime.RealtimeWebSocketHandler;
import com.guanlan.monitor.repository.AlertEventRepository;
import com.guanlan.monitor.repository.AlertRuleRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.PageRequest;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.List;
import java.util.Map;

@Service
@RequiredArgsConstructor
public class AlertService {
    private static final List<AlertEvent.Status> ACTIVE = List.of(AlertEvent.Status.OPEN, AlertEvent.Status.ACKNOWLEDGED);
    private final AlertRuleRepository rules;
    private final AlertEventRepository events;
    private final DeviceService devices;
    private final NotificationService notifications;
    private final RealtimeWebSocketHandler realtime;
    private final AuditService audit;

    @Transactional(readOnly = true)
    public List<AlertDtos.EventView> listEvents(int limit) {
        return events.findAllByOrderByStartedAtDesc(PageRequest.of(0, Math.min(Math.max(limit, 1), 500))).stream().map(this::eventView).toList();
    }

    @Transactional(readOnly = true)
    public List<AlertDtos.RuleView> listRules() {
        return rules.findAll().stream().map(this::ruleView).toList();
    }

    @Transactional(readOnly = true)
    public String ruleDeviceId(Long id) {
        return requireRule(id).getDevice() == null ? null : requireRule(id).getDevice().getId();
    }

    @Transactional
    public AlertDtos.RuleView createRule(AlertDtos.RuleRequest request) {
        validate(request);
        AlertRule rule = new AlertRule();
        apply(rule, request);
        rules.save(rule);
        audit.record("ALERT_RULE_CREATE", "rule:" + rule.getId(), "创建规则 " + rule.getName());
        return ruleView(rule);
    }

    @Transactional
    public AlertDtos.RuleView updateRule(Long id, AlertDtos.RuleRequest request) {
        validate(request);
        AlertRule rule = requireRule(id);
        apply(rule, request);
        audit.record("ALERT_RULE_UPDATE", "rule:" + id, "更新规则 " + rule.getName());
        return ruleView(rule);
    }

    @Transactional
    public void deleteRule(Long id) {
        AlertRule rule = requireRule(id);
        if (events.countByRuleId(id) > 0) {
            rule.setEnabled(false);
            audit.record("ALERT_RULE_DISABLE", "rule:" + id, "规则已有历史告警，已停用而非删除");
            return;
        }
        rules.delete(rule);
        audit.record("ALERT_RULE_DELETE", "rule:" + id, "删除规则 " + rule.getName());
    }

    @Transactional
    public AlertDtos.EventView acknowledge(Long id, String actor) {
        AlertEvent event = events.findById(id).orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "告警不存在"));
        if (event.getStatus() == AlertEvent.Status.OPEN) {
            event.setStatus(AlertEvent.Status.ACKNOWLEDGED);
            event.setAcknowledgedAt(Instant.now());
            event.setAcknowledgedBy(actor);
            audit.record("ALERT_ACK", "alert:" + id, "确认告警 " + event.getRule().getName());
        }
        return eventView(event);
    }

    @Transactional(readOnly = true)
    public String deviceId(Long id) {
        return events.findById(id)
                .map(event -> event.getDevice().getId())
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "告警不存在"));
    }

    @Transactional
    public void evaluateMetric(Device device, MetricSnapshot metric) {
        for (AlertRule rule : rules.findByEnabledTrue()) {
            if (rule.getMetric() == AlertRule.Metric.DEVICE_OFFLINE || !applies(rule, device)) continue;
            double value = switch (rule.getMetric()) {
                case CPU_USAGE -> metric.getCpuUsage();
                case MEMORY_USAGE -> metric.getMemoryUsage();
                case DISK_USAGE -> metric.getDiskUsage();
                case TCP_CONNECTIONS -> metric.getTcpConnections();
                case NETWORK_RECV_BPS -> metric.getNetworkRecvBps();
                case NETWORK_SENT_BPS -> metric.getNetworkSentBps();
                case TEMPERATURE -> metric.getTemperatureMax();
                case DEVICE_OFFLINE -> 0;
            };
            evaluate(rule, device, value, value >= rule.getThreshold());
        }
    }

    @Transactional
    public void evaluateOffline(Device device, double offlineSeconds) {
        for (AlertRule rule : rules.findByEnabledTrue()) {
            if (rule.getMetric() == AlertRule.Metric.DEVICE_OFFLINE && applies(rule, device)) {
                evaluate(rule, device, offlineSeconds, offlineSeconds >= rule.getThreshold());
            }
        }
    }

    private void evaluate(AlertRule rule, Device device, double value, boolean breached) {
        var active = events.findFirstByDeviceIdAndRuleIdAndStatusInOrderByStartedAtDesc(device.getId(), rule.getId(), ACTIVE);
        if (breached && active.isEmpty()) {
            AlertEvent event = new AlertEvent();
            event.setDevice(device);
            event.setRule(rule);
            event.setValue(value);
            event.setStartedAt(Instant.now());
            event.setStatus(AlertEvent.Status.OPEN);
            event.setMessage(message(rule, device, value));
            events.save(event);
            notifications.send(event);
            realtime.broadcast(Map.of("type", "alert.opened", "payload", eventView(event)));
        } else if (!breached && active.isPresent()) {
            AlertEvent event = active.get();
            event.setStatus(AlertEvent.Status.RESOLVED);
            event.setResolvedAt(Instant.now());
            realtime.broadcast(Map.of("type", "alert.resolved", "payload", eventView(event)));
        }
    }

    private boolean applies(AlertRule rule, Device device) {
        return rule.getDevice() == null || rule.getDevice().getId().equals(device.getId());
    }

    private void apply(AlertRule rule, AlertDtos.RuleRequest request) {
        rule.setName(request.name().trim());
        rule.setMetric(request.metric());
        rule.setThreshold(request.threshold());
        rule.setSeverity(request.severity());
        rule.setEnabled(request.enabled());
        rule.setDevice(request.deviceId() == null || request.deviceId().isBlank() ? null : devices.require(request.deviceId()));
    }

    private void validate(AlertDtos.RuleRequest request) {
        if (request == null || request.name() == null || request.name().isBlank() || request.metric() == null || request.severity() == null
                || !Double.isFinite(request.threshold()) || request.threshold() < 0) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "告警规则内容无效");
        }
        if (request.metric() == AlertRule.Metric.CPU_USAGE || request.metric() == AlertRule.Metric.MEMORY_USAGE || request.metric() == AlertRule.Metric.DISK_USAGE) {
            if (request.threshold() > 100) {
                throw new ApiException(HttpStatus.BAD_REQUEST, "资源使用率阈值必须在 0-100 之间");
            }
        }
    }

    private String message(AlertRule rule, Device device, double value) {
        String metric = switch (rule.getMetric()) {
            case CPU_USAGE -> "CPU 使用率";
            case MEMORY_USAGE -> "内存使用率";
            case DISK_USAGE -> "磁盘使用率";
            case TCP_CONNECTIONS -> "TCP 连接数";
            case NETWORK_RECV_BPS -> "网络接收速率";
            case NETWORK_SENT_BPS -> "网络发送速率";
            case TEMPERATURE -> "最高温度";
            case DEVICE_OFFLINE -> "离线时长";
        };
        String unit = switch (rule.getMetric()) {
            case DEVICE_OFFLINE -> " 秒";
            case TCP_CONNECTIONS -> " 个";
            case NETWORK_RECV_BPS, NETWORK_SENT_BPS -> " B/s";
            case TEMPERATURE -> " °C";
            default -> "%";
        };
        return device.getName() + " 的" + metric + "达到 " + String.format("%.1f", value) + unit + "，规则阈值 " + rule.getThreshold() + unit;
    }

    private AlertRule requireRule(Long id) {
        return rules.findById(id).orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "告警规则不存在"));
    }

    private AlertDtos.RuleView ruleView(AlertRule rule) {
        return new AlertDtos.RuleView(rule.getId(), rule.getName(), rule.getDevice() == null ? null : rule.getDevice().getId(),
                rule.getDevice() == null ? null : rule.getDevice().getName(), rule.getMetric(), rule.getThreshold(),
                rule.getSeverity(), rule.isEnabled(), rule.getUpdatedAt());
    }

    private AlertDtos.EventView eventView(AlertEvent event) {
        return new AlertDtos.EventView(event.getId(), event.getDevice().getId(), event.getDevice().getName(),
                event.getRule().getId(), event.getRule().getName(), event.getRule().getSeverity(), event.getStatus(),
                event.getValue(), event.getMessage(), event.getStartedAt(), event.getAcknowledgedAt(),
                event.getAcknowledgedBy(), event.getResolvedAt());
    }
}
