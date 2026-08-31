package com.guanlan.monitor.service;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
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
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.data.domain.PageRequest;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.List;
import java.util.Map;

@Service
@RequiredArgsConstructor(onConstructor_ = @Autowired)
public class AlertService {
    private static final List<AlertEvent.Status> ACTIVE = List.of(AlertEvent.Status.OPEN, AlertEvent.Status.ACKNOWLEDGED);
    private final AlertRuleRepository rules;
    private final AlertEventRepository events;
    private final DeviceService devices;
    private final NotificationService notifications;
    private final RealtimeWebSocketHandler realtime;
    private final AuditService audit;
    private final ObjectMapper mapper;
    private MaintenanceWindowService maintenanceWindows;

    /** Keeps isolated service tests source-compatible while Spring uses the full constructor. */
    public AlertService(AlertRuleRepository rules, AlertEventRepository events, DeviceService devices,
                        NotificationService notifications, RealtimeWebSocketHandler realtime, AuditService audit) {
        this(rules, events, devices, notifications, realtime, audit, new ObjectMapper());
    }

    @Autowired
    void setMaintenanceWindows(MaintenanceWindowService maintenanceWindows) {
        this.maintenanceWindows = maintenanceWindows;
    }

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
            Double value = switch (rule.getMetric()) {
                case CPU_USAGE -> metric.getCpuUsage();
                case MEMORY_USAGE -> metric.getMemoryUsage();
                case DISK_USAGE -> metric.getDiskUsage();
                case LOAD_1 -> metric.getLoad1();
                case DISK_READ_BPS -> metric.getDiskReadBps();
                case DISK_WRITE_BPS -> metric.getDiskWriteBps();
                case CONTAINER_CPU_USAGE -> metric.getContainerCpuUsage();
                case CONTAINER_MEMORY_USAGE -> metric.getContainerMemoryUsage();
                case GPU_USAGE -> metric.getGpuUsage();
                case BATTERY_PERCENT -> metric.getBatteryPercent();
                case SMART_FAILURES -> (double) metric.getSmartFailed();
                case INTEGRITY_CHANGES -> (double) metric.getIntegrityChanges();
                case FIREWALL_INACTIVE -> metric.getFirewallInactive() == null ? null : metric.getFirewallInactive().doubleValue();
                case TCP_CONNECTIONS -> (double) metric.getTcpConnections();
                case NETWORK_RECV_BPS -> metric.getNetworkRecvBps();
                case NETWORK_SENT_BPS -> metric.getNetworkSentBps();
                case TEMPERATURE -> metric.getTemperatureMax();
                case DEVICE_OFFLINE -> 0d;
                case PROCESS_MISSING -> processMissing(metric, rule.getTargetName());
                case SERVICE_NOT_RUNNING -> serviceNotRunning(metric, rule.getTargetName());
                case CUSTOM_METRIC -> customMetric(metric, rule.getTargetName());
            };
            if (value == null || !Double.isFinite(value)) continue;
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
        boolean muted = maintenanceWindows != null && maintenanceWindows.isMuted(device, rule, Instant.now());
        if (breached && active.isEmpty()) {
            AlertEvent event = new AlertEvent();
            event.setDevice(device);
            event.setRule(rule);
            event.setValue(value);
            event.setStartedAt(Instant.now());
            event.setStatus(AlertEvent.Status.OPEN);
            event.setMessage(message(rule, device, value));
            event.setNotificationSuppressed(muted);
            events.save(event);
            if (!muted) {
                notifications.send(event);
                event.setNotifiedAt(Instant.now());
            }
            realtime.broadcast(Map.of("type", "alert.opened", "payload", eventView(event)));
        } else if (breached && active.isPresent() && active.get().isNotificationSuppressed() && !muted) {
            AlertEvent event = active.get();
            event.setNotificationSuppressed(false);
            event.setNotifiedAt(Instant.now());
            notifications.send(event);
            realtime.broadcast(Map.of("type", "alert.updated", "payload", eventView(event)));
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
        rule.setTargetName(request.targetName() == null || request.targetName().isBlank() ? null : request.targetName().trim());
        rule.setSeverity(request.severity());
        rule.setEnabled(request.enabled());
        rule.setDevice(request.deviceId() == null || request.deviceId().isBlank() ? null : devices.require(request.deviceId()));
    }

    private void validate(AlertDtos.RuleRequest request) {
        if (request == null || request.name() == null || request.name().isBlank() || request.metric() == null || request.severity() == null
                || !Double.isFinite(request.threshold()) || request.threshold() < 0) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "告警规则内容无效");
        }
        if (request.metric() == AlertRule.Metric.CPU_USAGE || request.metric() == AlertRule.Metric.MEMORY_USAGE
                || request.metric() == AlertRule.Metric.DISK_USAGE || request.metric() == AlertRule.Metric.CONTAINER_MEMORY_USAGE
                || request.metric() == AlertRule.Metric.GPU_USAGE || request.metric() == AlertRule.Metric.BATTERY_PERCENT) {
            if (request.threshold() > 100) {
                throw new ApiException(HttpStatus.BAD_REQUEST, "资源使用率阈值必须在 0-100 之间");
            }
        }
        if (request.metric() == AlertRule.Metric.FIREWALL_INACTIVE && request.threshold() != 1) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "防火墙告警阈值必须为 1（未启用）");
        }
        if ((request.metric() == AlertRule.Metric.PROCESS_MISSING || request.metric() == AlertRule.Metric.SERVICE_NOT_RUNNING
                || request.metric() == AlertRule.Metric.CUSTOM_METRIC)
                && (request.targetName() == null || request.targetName().isBlank())) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "目标型告警必须填写目标名称");
        }
        if ((request.metric() == AlertRule.Metric.PROCESS_MISSING || request.metric() == AlertRule.Metric.SERVICE_NOT_RUNNING)
                && request.threshold() != 1) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "进程或服务告警阈值必须为 1");
        }
    }

    private String message(AlertRule rule, Device device, double value) {
        String metric = switch (rule.getMetric()) {
            case CPU_USAGE -> "CPU 使用率";
            case MEMORY_USAGE -> "内存使用率";
            case DISK_USAGE -> "磁盘使用率";
            case LOAD_1 -> "1 分钟负载";
            case DISK_READ_BPS -> "磁盘读取速率";
            case DISK_WRITE_BPS -> "磁盘写入速率";
            case CONTAINER_CPU_USAGE -> "容器 CPU 使用率";
            case CONTAINER_MEMORY_USAGE -> "容器内存使用率";
            case GPU_USAGE -> "GPU 使用率";
            case BATTERY_PERCENT -> "电池电量";
            case SMART_FAILURES -> "SMART 失败磁盘数";
            case INTEGRITY_CHANGES -> "完整性变更文件数";
            case FIREWALL_INACTIVE -> "防火墙未启用";
            case TCP_CONNECTIONS -> "TCP 连接数";
            case NETWORK_RECV_BPS -> "网络接收速率";
            case NETWORK_SENT_BPS -> "网络发送速率";
            case TEMPERATURE -> "最高温度";
            case DEVICE_OFFLINE -> "离线时长";
            case PROCESS_MISSING -> "关键进程缺失";
            case SERVICE_NOT_RUNNING -> "系统服务未运行";
            case CUSTOM_METRIC -> "自定义监控项";
        };
        String unit = switch (rule.getMetric()) {
            case DEVICE_OFFLINE -> " 秒";
            case TCP_CONNECTIONS, SMART_FAILURES, INTEGRITY_CHANGES -> " 个";
            case FIREWALL_INACTIVE -> "";
            case NETWORK_RECV_BPS, NETWORK_SENT_BPS -> " B/s";
            case DISK_READ_BPS, DISK_WRITE_BPS -> " B/s";
            case LOAD_1 -> "";
            case TEMPERATURE -> " °C";
            case PROCESS_MISSING, SERVICE_NOT_RUNNING, CUSTOM_METRIC -> "";
            default -> "%";
        };
        String target = (rule.getMetric() == AlertRule.Metric.PROCESS_MISSING || rule.getMetric() == AlertRule.Metric.SERVICE_NOT_RUNNING
                || rule.getMetric() == AlertRule.Metric.CUSTOM_METRIC)
                && !blank(rule.getTargetName()) ? "（" + rule.getTargetName().trim() + "）" : "";
        return device.getName() + " 的" + metric + target + "达到 " + String.format("%.1f", value) + unit + "，规则阈值 " + rule.getThreshold() + unit;
    }

    private Double processMissing(MetricSnapshot metric, String targetName) {
        if (blank(targetName) || blank(metric.getProcessesJson())) return null;
        try {
            List<Map<String, Object>> processes = mapper.readValue(metric.getProcessesJson(), new TypeReference<>() {});
            if (processes.isEmpty()) return null;
            boolean present = processes.stream().anyMatch(item -> sameName(item.get("name"), targetName));
            return present ? 0d : 1d;
        } catch (Exception ignored) {
            return null;
        }
    }

    private Double serviceNotRunning(MetricSnapshot metric, String targetName) {
        if (blank(targetName) || blank(metric.getServicesJson())) return null;
        try {
            List<Map<String, Object>> services = mapper.readValue(metric.getServicesJson(), new TypeReference<>() {});
            if (services.isEmpty()) return null;
            boolean running = services.stream().filter(item -> sameName(item.get("name"), targetName))
                    .anyMatch(item -> {
                        Object status = item.get("status");
                        return status != null && ("running".equalsIgnoreCase(String.valueOf(status).trim())
                                || "active".equalsIgnoreCase(String.valueOf(status).trim()));
                    });
            return running ? 0d : 1d;
        } catch (Exception ignored) {
            return null;
        }
    }

    private Double customMetric(MetricSnapshot metric, String targetName) {
        if (blank(targetName) || blank(metric.getCustomMetricsJson())) return null;
        try {
            List<Map<String, Object>> values = mapper.readValue(metric.getCustomMetricsJson(), new TypeReference<>() {});
            for (Map<String, Object> item : values) {
                if (!sameName(item.get("name"), targetName)) continue;
                Object value = item.get("value");
                if (value instanceof Number number && Double.isFinite(number.doubleValue())) return number.doubleValue();
                return null;
            }
        } catch (Exception ignored) {
            return null;
        }
        return null;
    }

    private boolean sameName(Object value, String targetName) {
        if (value == null) return false;
        String left = String.valueOf(value).trim();
        String right = targetName.trim();
        if (left.equalsIgnoreCase(right)) return true;
        return left.endsWith(".exe") && right.endsWith(".exe")
                ? left.substring(0, left.length() - 4).equalsIgnoreCase(right.substring(0, right.length() - 4))
                : false;
    }

    private boolean blank(String value) { return value == null || value.isBlank(); }

    private AlertRule requireRule(Long id) {
        return rules.findById(id).orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "告警规则不存在"));
    }

    private AlertDtos.RuleView ruleView(AlertRule rule) {
        return new AlertDtos.RuleView(rule.getId(), rule.getName(), rule.getDevice() == null ? null : rule.getDevice().getId(),
                rule.getDevice() == null ? null : rule.getDevice().getName(), rule.getMetric(), rule.getThreshold(),
                rule.getSeverity(), rule.getTargetName(), rule.isEnabled(), rule.getUpdatedAt());
    }

    private AlertDtos.EventView eventView(AlertEvent event) {
        return new AlertDtos.EventView(event.getId(), event.getDevice().getId(), event.getDevice().getName(),
                event.getRule().getId(), event.getRule().getName(), event.getRule().getSeverity(), event.getStatus(),
                event.getValue(), event.getMessage(), event.getStartedAt(), event.getAcknowledgedAt(),
                event.getAcknowledgedBy(), event.getResolvedAt(), event.isNotificationSuppressed(), event.getNotifiedAt());
    }
}
