package com.guanlan.monitor;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.repository.DeviceRepository;
import com.guanlan.monitor.service.DeviceService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.test.context.ActiveProfiles;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

@SpringBootTest(properties = {
        "app.controller-agent.enabled=true",
        "app.controller-agent.device-id=8d7d03bc-32fe-4c48-8b93-2942b1b153c1",
        "app.controller-agent.key=controller-agent-test-key-0123456789",
        "app.controller-agent.name=总控服务器",
        "app.controller-agent.group-name=控制平面"
})
@ActiveProfiles("test")
class ControllerAgentProvisionerIntegrationTest {
    private static final String DEVICE_ID = "8d7d03bc-32fe-4c48-8b93-2942b1b153c1";
    private static final String AGENT_KEY = "controller-agent-test-key-0123456789";

    @Autowired DeviceRepository devices;
    @Autowired DeviceService deviceService;
    @Autowired PasswordEncoder passwordEncoder;

    @Test
    void provisionsAndProtectsTheControllerHostDevice() {
        var device = devices.findById(DEVICE_ID).orElseThrow();

        assertThat(device.getName()).isEqualTo("总控服务器");
        assertThat(device.getGroupName()).isEqualTo("控制平面");
        assertThat(device.isControllerManaged()).isTrue();
        assertThat(passwordEncoder.matches(AGENT_KEY, device.getAgentKeyHash())).isTrue();
        assertThatThrownBy(() -> deviceService.regenerateKey(DEVICE_ID))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("不能轮换");
        assertThatThrownBy(() -> deviceService.delete(DEVICE_ID))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("不能删除");
    }
}
