package com.guanlan.monitor.service;

import com.guanlan.monitor.domain.AlertRule;
import com.guanlan.monitor.repository.AlertRuleRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

@Component
@RequiredArgsConstructor
public class DefaultAlertRules implements ApplicationRunner {
    private final AlertRuleRepository rules;

    @Override
    @Transactional
    public void run(ApplicationArguments args) {
        if (rules.count() > 0) return;
        add("CPU 高负载", AlertRule.Metric.CPU_USAGE, 90, AlertRule.Severity.CRITICAL);
        add("内存高负载", AlertRule.Metric.MEMORY_USAGE, 95, AlertRule.Severity.CRITICAL);
        add("磁盘空间不足", AlertRule.Metric.DISK_USAGE, 90, AlertRule.Severity.WARNING);
        add("设备离线", AlertRule.Metric.DEVICE_OFFLINE, 30, AlertRule.Severity.CRITICAL);
    }

    private void add(String name, AlertRule.Metric metric, double threshold, AlertRule.Severity severity) {
        AlertRule rule = new AlertRule();
        rule.setName(name);
        rule.setMetric(metric);
        rule.setThreshold(threshold);
        rule.setSeverity(severity);
        rule.setEnabled(true);
        rules.save(rule);
    }
}

