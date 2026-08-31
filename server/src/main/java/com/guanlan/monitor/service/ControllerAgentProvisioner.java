package com.guanlan.monitor.service;

import com.guanlan.monitor.config.AppProperties;
import com.guanlan.monitor.domain.Device;
import com.guanlan.monitor.repository.DeviceRepository;
import lombok.RequiredArgsConstructor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.context.annotation.Profile;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

@Component
@Profile("!bootstrap")
@RequiredArgsConstructor
public class ControllerAgentProvisioner implements ApplicationRunner {
    private static final Logger log = LoggerFactory.getLogger(ControllerAgentProvisioner.class);

    private final AppProperties properties;
    private final DeviceRepository devices;
    private final PasswordEncoder passwordEncoder;
    private final DeviceStatusHistoryService statusHistory;

    @Override
    @Transactional
    public void run(ApplicationArguments args) {
        AppProperties.ControllerAgent config = properties.getControllerAgent();
        if (!config.isEnabled()) return;

        String id = trim(config.getDeviceId());
        String key = trim(config.getKey());
        if (id.isEmpty() || id.length() > 36 || key.length() < 24) {
            log.warn("Controller host monitoring is enabled but its internal credentials are incomplete.");
            return;
        }

        Device existing = devices.findById(id).orElse(null);
        if (existing != null) {
            if (!existing.isControllerManaged()) {
                log.warn("Controller host device ID is already assigned to a non-managed device.");
                return;
            }
            if (!passwordEncoder.matches(key, existing.getAgentKeyHash())) {
                existing.setAgentKeyHash(passwordEncoder.encode(key));
                existing.setAgentKeyPrefix(key.substring(0, 8));
                log.info("Controller host device credentials were synchronized.");
            }
            return;
        }

        Device device = new Device();
        device.setId(id);
        device.setName(limit(trim(config.getName()), 100, "总控服务器"));
        device.setGroupName(limit(trim(config.getGroupName()), 80, "控制平面"));
        device.setAgentKeyHash(passwordEncoder.encode(key));
        device.setAgentKeyPrefix(key.substring(0, 8));
        device.setControllerManaged(true);
        devices.save(device);
        statusHistory.record(device, null, Device.Status.PENDING, "总控 Agent 已登记，等待首次上报");
        log.info("Controller host device provisioned.");
    }

    private String trim(String value) {
        return value == null ? "" : value.trim();
    }

    private String limit(String value, int length, String fallback) {
        String resolved = value.isEmpty() ? fallback : value;
        return resolved.length() <= length ? resolved : resolved.substring(0, length);
    }
}
