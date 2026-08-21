package com.guanlan.monitor;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.api.dto.DeviceDtos;
import com.guanlan.monitor.domain.AlertEvent;
import com.guanlan.monitor.domain.Device;
import com.guanlan.monitor.domain.SystemSetting;
import com.guanlan.monitor.repository.AlertEventRepository;
import com.guanlan.monitor.repository.DeviceRepository;
import com.guanlan.monitor.repository.SystemSettingRepository;
import com.guanlan.monitor.service.AlertService;
import com.guanlan.monitor.service.DeviceService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.mock.web.MockHttpSession;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;

import java.time.Instant;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
class AuthAndAgentIntegrationTest {
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @Autowired DeviceService devices;
    @Autowired DeviceRepository deviceRepository;
    @Autowired AlertEventRepository alertEvents;
    @Autowired AlertService alertService;
    @Autowired SystemSettingRepository settings;

    @Test
    void publicBrandUsesPersistedSiteNameWithoutAuthentication() throws Exception {
        settings.save(new SystemSetting("system.site_name", "现场监控"));
        settings.save(new SystemSetting("system.site_icon_url", "https://example.com/icon.svg"));

        mvc.perform(get("/api/settings/public"))
                .andExpect(status().isOk())
                .andExpect(header().string("Cache-Control", "no-store"))
                .andExpect(jsonPath("$.siteName").value("现场监控"))
                .andExpect(jsonPath("$.siteIconUrl").value("https://example.com/icon.svg"));
    }

    @Test
    void publicBrandUsesTheNewDefaultWhenNoSettingHasBeenSaved() throws Exception {
        settings.deleteById("system.site_name");

        mvc.perform(get("/api/settings/public"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.siteName").value("星辰云巡"))
                .andExpect(jsonPath("$.siteIconUrl").value("/favicon.svg"));
    }

    @Test
    void loginCreatesAUsableServerSession() throws Exception {
        var result = mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/auth/login")
                        .with(csrf())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"username":"test-admin","password":"Test-only-password-123","returnTo":"//outside.example"}
                                """))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.user.role").value("ADMIN"))
                .andExpect(jsonPath("$.returnTo").value("/dashboard"))
                .andReturn();

        MockHttpSession session = (MockHttpSession) result.getRequest().getSession(false);
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get("/api/auth/me").session(session))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.username").value("test-admin"));
    }

    @Test
    @WithMockUser(roles = "VIEWER")
    void viewerCannotCreateDevices() throws Exception {
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/devices")
                        .with(csrf())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"blocked\"}"))
                .andExpect(status().isForbidden());
    }

    @Test
    @WithMockUser(roles = "VIEWER")
    void viewerCannotReadControllerUpdateStatus() throws Exception {
        mvc.perform(get("/api/admin/controller-update"))
                .andExpect(status().isForbidden());
    }

    @Test
    @WithMockUser(roles = "ADMIN")
    void controllerUpdateActionsRequireCsrf() throws Exception {
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/admin/controller-update/check"))
                .andExpect(status().isForbidden());
    }

    @Test
    void agentKeyControlsMetricIngestion() throws Exception {
        DeviceDtos.Credential credential = devices.create(new DeviceDtos.CreateRequest("integration-node", "lab", "tests", "127.0.0.1"));
        settings.save(new com.guanlan.monitor.domain.SystemSetting("agent.default_collection_seconds", "10"));
        String report = sampleReport();

                mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/agent/v1/reports")
                        .header("X-Device-Id", credential.device().id())
                        .header("X-Agent-Key", credential.agentKey())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(report))
                .andExpect(status().isAccepted())
                .andExpect(header().string("X-Agent-Interval-Seconds", "10"))
                .andExpect(jsonPath("$.cpuUsage").value(42.5));

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/agent/v1/reports")
                        .header("X-Device-Id", credential.device().id())
                        .header("X-Agent-Key", "invalid-key")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(report))
                .andExpect(status().isUnauthorized());
    }

    @Test
    void agentAcceptsMultiCoreProcessCpuUsage() throws Exception {
        DeviceDtos.Credential credential = devices.create(new DeviceDtos.CreateRequest("multicore-node", "lab", "tests", "127.0.0.3"));
        String report = sampleReport().replace("\"processes\":[]", "\"processes\":[{\"pid\":42,\"name\":\"worker\",\"username\":\"root\",\"cpuPercent\":185.5,\"memoryPercent\":2.5,\"status\":\"running\"}]");

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/agent/v1/reports")
                        .header("X-Device-Id", credential.device().id())
                        .header("X-Agent-Key", credential.agentKey())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(report))
                .andExpect(status().isAccepted());
    }

    @Test
    void agentRecoveryResolvesAnOfflineAlert() throws Exception {
        DeviceDtos.Credential credential = devices.create(new DeviceDtos.CreateRequest("recovery-node", "lab", "tests", "127.0.0.2"));
        Device device = deviceRepository.findById(credential.device().id()).orElseThrow();
        device.setStatus(Device.Status.OFFLINE);
        device.setLastSeenAt(Instant.now().minusSeconds(45));
        deviceRepository.save(device);
        alertService.evaluateOffline(device, 45);
        assertThat(alertEvents.findAll()).anyMatch(event -> event.getDevice().getId().equals(device.getId()) && event.getStatus() == AlertEvent.Status.OPEN);

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/agent/v1/reports")
                        .header("X-Device-Id", credential.device().id())
                        .header("X-Agent-Key", credential.agentKey())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(sampleReport()))
                .andExpect(status().isAccepted());

        assertThat(alertEvents.findAll()).anyMatch(event -> event.getDevice().getId().equals(device.getId()) && event.getStatus() == AlertEvent.Status.RESOLVED);
    }

    private String sampleReport() throws Exception {
        return mapper.writeValueAsString(Map.of(
                "collectedAt", Instant.now().toString(),
                "host", Map.of("hostname", "test-host", "os", "linux", "platform", "ubuntu", "platformVersion", "24.04", "kernelVersion", "6.8", "architecture", "amd64", "uptimeSeconds", 100, "bootTime", 1, "temperatures", java.util.List.of()),
                "cpu", Map.of("model", "test-cpu", "logicalCores", 4, "physicalCores", 2, "usagePercent", 42.5, "perCorePercent", java.util.List.of(40, 45), "load1", 0.4, "load5", 0.3, "load15", 0.2),
                "memory", Map.of("totalBytes", 1024, "usedBytes", 512, "availableBytes", 512, "usagePercent", 50, "cachedBytes", 0, "swapTotalBytes", 0, "swapUsedBytes", 0, "swapPercent", 0),
                "disks", java.util.List.of(Map.of("device", "sda", "mountpoint", "/", "fileSystem", "ext4", "totalBytes", 1024, "usedBytes", 800, "freeBytes", 224, "usagePercent", 78.1, "readBytesPerSec", 100, "writeBytesPerSec", 50)),
                "network", Map.of("bytesSentPerSec", 10, "bytesRecvPerSec", 20, "tcpConnections", 3),
                "processes", java.util.List.of(),
                "services", java.util.List.of()
        ));
    }
}
