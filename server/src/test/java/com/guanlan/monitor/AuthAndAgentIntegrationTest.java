package com.guanlan.monitor;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.api.dto.DeviceDtos;
import com.guanlan.monitor.api.dto.ApiTokenDtos;
import com.guanlan.monitor.domain.AlertEvent;
import com.guanlan.monitor.domain.AgentTask;
import com.guanlan.monitor.domain.DdnsConfig;
import com.guanlan.monitor.domain.Device;
import com.guanlan.monitor.domain.SystemSetting;
import com.guanlan.monitor.domain.UserAccount;
import com.guanlan.monitor.domain.UserDevicePermission;
import com.guanlan.monitor.repository.AlertEventRepository;
import com.guanlan.monitor.repository.AgentTaskRepository;
import com.guanlan.monitor.repository.DeviceRepository;
import com.guanlan.monitor.repository.DdnsConfigRepository;
import com.guanlan.monitor.repository.MetricSnapshotRepository;
import com.guanlan.monitor.repository.SystemSettingRepository;
import com.guanlan.monitor.repository.UserAccountRepository;
import com.guanlan.monitor.repository.UserDevicePermissionRepository;
import com.guanlan.monitor.service.AlertService;
import com.guanlan.monitor.service.ApiTokenService;
import com.guanlan.monitor.service.DeviceService;
import com.guanlan.monitor.service.MaintenanceJobs;
import com.guanlan.monitor.service.TotpService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.mock.web.MockHttpSession;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;

import java.time.Duration;
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
    @Autowired DdnsConfigRepository ddnsConfigs;
    @Autowired MetricSnapshotRepository metricSnapshots;
    @Autowired AlertEventRepository alertEvents;
    @Autowired AlertService alertService;
    @Autowired ApiTokenService apiTokens;
    @Autowired AgentTaskRepository agentTasks;
    @Autowired MaintenanceJobs maintenanceJobs;
    @Autowired SystemSettingRepository settings;
    @Autowired UserAccountRepository userAccounts;
    @Autowired UserDevicePermissionRepository devicePermissions;
    @Autowired PasswordEncoder passwordEncoder;
    @Autowired TotpService totp;

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
                .andExpect(jsonPath("$.siteName").value("星辰监控"))
                .andExpect(jsonPath("$.siteIconUrl").value("/brand-icon.png"));
    }

    @Test
    void publicOverviewOnlyIncludesDevicesMarkedPublic() throws Exception {
        DeviceDtos.Credential hidden = devices.create(new DeviceDtos.CreateRequest("hidden-node", "lab", "tests", "127.0.0.7"));
        devices.update(hidden.device().id(), new DeviceDtos.UpdateRequest("hidden-node", "lab", "tests", "127.0.0.7", false, null, false));
        DeviceDtos.Credential visible = devices.create(new DeviceDtos.CreateRequest("visible-node", "lab", "tests", "127.0.0.8"));

        mvc.perform(get("/api/public/overview"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.devices[?(@.id == '" + hidden.device().id() + "')]").doesNotExist())
                .andExpect(jsonPath("$.devices[?(@.id == '" + visible.device().id() + "')]").isArray());
    }

    @Test
    void publicServiceEndpointIsAccessibleWithoutAuthentication() throws Exception {
        mvc.perform(get("/api/services/public"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$").isArray());
    }

    @Test
    @WithMockUser(username = "test-admin", roles = "ADMIN")
    void deviceHealthEndpointExplainsPendingAgentConnection() throws Exception {
        DeviceDtos.Credential credential = devices.create(new DeviceDtos.CreateRequest("health-node", "lab", "tests", "127.0.0.30"));

        mvc.perform(get("/api/devices/" + credential.device().id() + "/health"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.state").value("PENDING"))
                .andExpect(jsonPath("$.reasonCode").value("NOT_CONNECTED"))
                .andExpect(jsonPath("$.lastSeenAgeSeconds").doesNotExist())
                .andExpect(jsonPath("$.checks").isArray());
    }

    @Test
    @WithMockUser(username = "operator", roles = "OPERATOR")
    void deviceAssetsAndNotesArePersistedAndScopedToDevice() throws Exception {
        DeviceDtos.Credential credential = devices.create(new DeviceDtos.CreateRequest("asset-node", "lab", "tests", "127.0.0.31"));
        grantAccess("operator", UserAccount.Role.OPERATOR, credential.device().id(), true, false, false);

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put("/api/devices/" + credential.device().id())
                        .with(csrf()).contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"name":"asset-node","location":"机房 A3","groupName":"生产","primaryIp":"10.0.0.31","tags":["核心"],"assetTag":"SRV-001","ownerName":"运维一组","vendor":"Dell","model":"R760","serialNumber":"SN-001","environment":"production","purchaseDate":"2025-01-02","warrantyExpiresAt":"2028-01-02","description":"API 主节点","ddnsEnabled":false,"publicVisible":true}
                                """))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.assetTag").value("SRV-001"))
                .andExpect(jsonPath("$.ownerName").value("运维一组"))
                .andExpect(jsonPath("$.warrantyExpiresAt").value("2028-01-02"));

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/devices/" + credential.device().id() + "/notes")
                        .with(csrf()).contentType(MediaType.APPLICATION_JSON).content("{\"content\":\"已完成系统补丁和服务重启\"}"))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.deviceId").value(credential.device().id()))
                .andExpect(jsonPath("$.content").value("已完成系统补丁和服务重启"));

        mvc.perform(get("/api/devices/" + credential.device().id() + "/notes"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[0].author").value("operator"));
    }

    @Test
    @WithMockUser(roles = "VIEWER")
    void agentStatusTransitionsAreRecorded() throws Exception {
        DeviceDtos.Credential credential = devices.create(new DeviceDtos.CreateRequest("history-node", "lab", "tests", "127.0.0.32"));
        grantAccess("user", UserAccount.Role.VIEWER, credential.device().id(), false, false, false);

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/agent/v1/reports")
                        .header("X-Device-Id", credential.device().id())
                        .header("X-Agent-Key", credential.agentKey())
                        .contentType(MediaType.APPLICATION_JSON).content(sampleReport()))
                .andExpect(status().isAccepted());

        mvc.perform(get("/api/devices/" + credential.device().id() + "/status-history"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[0].previousStatus").value("PENDING"))
                .andExpect(jsonPath("$[0].status").value("ONLINE"))
                .andExpect(jsonPath("$[0].reason").value("Agent 上报，设备恢复在线"));
    }

    @Test
    @WithMockUser(username = "operator", roles = "OPERATOR")
    void serviceMonitorRejectsMalformedHttpTarget() throws Exception {
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/services")
                        .with(csrf()).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"bad\",\"target\":\"http:///health\",\"type\":\"HTTP_GET\",\"intervalSeconds\":60,\"timeoutMs\":5000,\"publicVisible\":true,\"sortOrder\":0,\"enabled\":true,\"failureThreshold\":1,\"latencyThresholdMs\":0}"))
                .andExpect(status().isBadRequest());
    }

    @Test
    @WithMockUser(username = "operator", roles = "OPERATOR")
    void ddnsRejectsMalformedDomain() throws Exception {
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/ddns")
                        .with(csrf()).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"invalid-ddns\",\"provider\":\"DUMMY\",\"domains\":[\"bad domain/path\"],\"enabled\":true,\"ipv4Enabled\":true,\"ipv6Enabled\":false,\"maxRetries\":1}"))
                .andExpect(status().isBadRequest());
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
    void currentUserCanUpdateProfileAndChangePasswordWithCurrentPassword() throws Exception {
        UserAccount profileUser = new UserAccount();
        profileUser.setUsername("profile-test");
        profileUser.setDisplayName("资料测试");
        profileUser.setPasswordHash(passwordEncoder.encode("Profile-password-123"));
        profileUser.setRole(UserAccount.Role.VIEWER);
        profileUser.setEnabled(true);
        userAccounts.save(profileUser);
        var login = mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/auth/login")
                        .with(csrf())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"username\":\"profile-test\",\"password\":\"Profile-password-123\"}"))
                .andExpect(status().isOk()).andReturn();
        MockHttpSession session = (MockHttpSession) login.getRequest().getSession(false);

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put("/api/auth/profile")
                        .session(session).with(csrf()).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"displayName\":\"新的显示名\",\"currentPassword\":\"wrong-password\",\"newPassword\":\"Another-password-123\"}"))
                .andExpect(status().isUnauthorized());

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put("/api/auth/profile")
                        .session(session).with(csrf()).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"displayName\":\"新的显示名\",\"currentPassword\":\"Profile-password-123\",\"newPassword\":\"Another-password-123\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.displayName").value("新的显示名"));

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/auth/login")
                        .with(csrf()).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"username\":\"profile-test\",\"password\":\"Another-password-123\"}"))
                .andExpect(status().isOk());
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
    void viewerCannotWriteDdnsConfiguration() throws Exception {
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/ddns")
                        .with(csrf()).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"blocked-ddns\",\"provider\":\"DUMMY\",\"domains\":[\"node.example.com\"],\"enabled\":true,\"ipv4Enabled\":true,\"ipv6Enabled\":false,\"maxRetries\":3}"))
                .andExpect(status().isForbidden());
    }

    @Test
    @WithMockUser(roles = "VIEWER")
    void viewerCannotReadDdnsErrorDetails() throws Exception {
        DdnsConfig config = new DdnsConfig();
        config.setName("failed-ddns");
        config.setProvider(DdnsConfig.Provider.WEBHOOK);
        config.setDomains("node.example.com");
        config.setHttpMethod(DdnsConfig.HttpMethod.GET);
        config.setEnabled(true);
        config.setIpv4Enabled(true);
        config.setIpv6Enabled(false);
        config.setMaxRetries(1);
        config.setLastStatus("FAILED");
        config.setLastError("POST https://example.com/update?token=secret");
        ddnsConfigs.save(config);

        mvc.perform(get("/api/ddns"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[?(@.name == 'failed-ddns')].lastStatus").value(org.hamcrest.Matchers.hasItem("FAILED")))
                .andExpect(jsonPath("$[?(@.name == 'failed-ddns')].lastError").value(org.hamcrest.Matchers.hasItem(org.hamcrest.Matchers.nullValue())));
    }

    @Test
    @WithMockUser(username = "test-admin", roles = "ADMIN")
    void resourceAlertThresholdCannotExceedPercentRange() throws Exception {
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/alert-rules")
                        .with(csrf()).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"invalid-cpu\",\"metric\":\"CPU_USAGE\",\"threshold\":101,\"severity\":\"WARNING\",\"enabled\":true}"))
                .andExpect(status().isBadRequest());
    }

    @Test
    @WithMockUser(username = "test-admin", roles = "ADMIN")
    void tcpConnectionAlertRuleAcceptsConnectionCountThreshold() throws Exception {
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/alert-rules")
                        .with(csrf()).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"连接数过高\",\"metric\":\"TCP_CONNECTIONS\",\"threshold\":500,\"severity\":\"WARNING\",\"enabled\":true}"))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.metric").value("TCP_CONNECTIONS"))
                .andExpect(jsonPath("$.threshold").value(500));
    }

    @Test
    void userCanEnrollTwoFactorAndMustCompleteChallengeOnLogin() throws Exception {
        UserAccount account = new UserAccount();
        account.setUsername("totp-test");
        account.setDisplayName("TOTP 测试");
        account.setPasswordHash(passwordEncoder.encode("Totp-password-123"));
        account.setRole(UserAccount.Role.VIEWER);
        account.setEnabled(true);
        userAccounts.save(account);

        var login = mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/auth/login")
                        .with(csrf()).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"username\":\"totp-test\",\"password\":\"Totp-password-123\"}"))
                .andExpect(status().isOk()).andReturn();
        MockHttpSession session = (MockHttpSession) login.getRequest().getSession(false);

        var setup = mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/auth/2fa/setup")
                        .session(session).with(csrf()).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"currentPassword\":\"Totp-password-123\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.otpauthUri").value(org.hamcrest.Matchers.startsWith("otpauth://totp/")))
                .andReturn();
        String secret = mapper.readTree(setup.getResponse().getContentAsString()).get("secret").asText();
        String setupCode = totp.currentCode(secret, Instant.now());

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/auth/2fa/enable")
                        .session(session).with(csrf()).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"code\":\"" + setupCode + "\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.enabled").value(true));

        var challenge = mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/auth/login")
                        .with(csrf()).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"username\":\"totp-test\",\"password\":\"Totp-password-123\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.requiresTwoFactor").value(true))
                .andExpect(jsonPath("$.user").doesNotExist())
                .andReturn();
        MockHttpSession challengeSession = (MockHttpSession) challenge.getRequest().getSession(false);

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/auth/2fa/verify")
                        .session(challengeSession).with(csrf()).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"code\":\"000000\"}"))
                .andExpect(status().isUnauthorized());

        String loginCode = totp.currentCode(secret, Instant.now());
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/auth/2fa/verify")
                        .session(challengeSession).with(csrf()).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"code\":\"" + loginCode + "\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.user.username").value("totp-test"))
                .andExpect(jsonPath("$.requiresTwoFactor").value(false));

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/auth/2fa/disable")
                        .session(challengeSession).with(csrf()).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"currentPassword\":\"wrong-password\",\"code\":\"" + loginCode + "\"}"))
                .andExpect(status().isUnauthorized());
        String disableCode = totp.currentCode(secret, Instant.now());
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/auth/2fa/disable")
                        .session(challengeSession).with(csrf()).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"currentPassword\":\"Totp-password-123\",\"code\":\"" + disableCode + "\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.enabled").value(false));
    }

    @Test
    @WithMockUser(username = "operator", roles = "OPERATOR")
    void fanRpmAlertOpensAndResolvesFromAgentReports() throws Exception {
        DeviceDtos.Credential credential = devices.create(new DeviceDtos.CreateRequest("fan-alert-node", "lab", "tests", "127.0.0.41"));
        grantAccess("operator", UserAccount.Role.OPERATOR, credential.device().id(), false, true, false);

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/alert-rules")
                        .with(csrf()).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"风扇转速过高\",\"deviceId\":\"" + credential.device().id() + "\",\"metric\":\"FAN_RPM\",\"threshold\":2500,\"severity\":\"WARNING\",\"enabled\":true}"))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.metric").value("FAN_RPM"))
                .andExpect(jsonPath("$.threshold").value(2500));

        String breached = sampleReport().replace("\"temperatures\":[]", "\"temperatures\":[],\"fans\":[{\"name\":\"cpu_fan\",\"rpm\":1800},{\"name\":\"case_fan\",\"rpm\":3200}]");
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/agent/v1/reports")
                        .header("X-Device-Id", credential.device().id()).header("X-Agent-Key", credential.agentKey())
                        .contentType(MediaType.APPLICATION_JSON).content(breached))
                .andExpect(status().isAccepted());
        assertThat(alertEvents.findAll()).anyMatch(event -> event.getDevice().getId().equals(credential.device().id())
                && event.getStatus() == AlertEvent.Status.OPEN && event.getMessage().contains("风扇转速")
                && event.getValue() == 3200);

        String recovered = sampleReport().replace("\"temperatures\":[]", "\"temperatures\":[],\"fans\":[{\"name\":\"cpu_fan\",\"rpm\":900},{\"name\":\"case_fan\",\"rpm\":1200}]");
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/agent/v1/reports")
                        .header("X-Device-Id", credential.device().id()).header("X-Agent-Key", credential.agentKey())
                        .contentType(MediaType.APPLICATION_JSON).content(recovered))
                .andExpect(status().isAccepted());
        assertThat(alertEvents.findAll()).anyMatch(event -> event.getDevice().getId().equals(credential.device().id())
                && event.getStatus() == AlertEvent.Status.RESOLVED);
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
    void agentPersistsNetworkInventoryAndTemperature() throws Exception {
        DeviceDtos.Credential credential = devices.create(new DeviceDtos.CreateRequest("inventory-node", "lab", "tests", "127.0.0.4"));
        String report = sampleReport()
                .replace("\"temperatures\":[]", "\"temperatures\":[{\"sensor\":\"cpu-package\",\"value\":72.5}]")
                .replace("\"processes\":[]", "\"networkInterfaces\":[{\"name\":\"eth0\",\"mtu\":1500,\"hardwareAddr\":\"00:11:22:33:44:55\",\"flags\":[\"up\"],\"addresses\":[\"10.0.0.4\"]}],\"ports\":[{\"protocol\":\"TCP\",\"address\":\"0.0.0.0\",\"port\":443,\"pid\":12}],\"containers\":[{\"id\":\"abc123\",\"name\":\"api\",\"image\":\"example/api:latest\",\"state\":\"running\",\"status\":\"Up 2 hours\",\"cpuPercent\":12.5,\"memoryUsageBytes\":800,\"memoryLimitBytes\":1000,\"memoryPercent\":80.0,\"networkRxBytes\":13,\"networkTxBytes\":27,\"restartCount\":0}],\"processes\":[]");

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/agent/v1/reports")
                        .header("X-Device-Id", credential.device().id())
                        .header("X-Agent-Key", credential.agentKey())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(report))
                .andExpect(status().isAccepted())
                .andExpect(jsonPath("$.temperatureMax").value(72.5))
                .andExpect(jsonPath("$.networkInterfaces[0].name").value("eth0"))
                .andExpect(jsonPath("$.ports[0].port").value(443))
                .andExpect(jsonPath("$.containers[0].name").value("api"));
    }

    @Test
    void agentRejectsNegativeMemoryCounters() throws Exception {
        DeviceDtos.Credential credential = devices.create(new DeviceDtos.CreateRequest("invalid-memory-node", "lab", "tests", "127.0.0.4"));
        String report = sampleReport().replace("\"totalBytes\":1024", "\"totalBytes\":-1");

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/agent/v1/reports")
                        .header("X-Device-Id", credential.device().id())
                        .header("X-Agent-Key", credential.agentKey())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(report))
                .andExpect(status().isBadRequest());
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

    @Test
    void apiTokenEnforcesScopeAndCanBeRevoked() throws Exception {
        ApiTokenDtos.Created created = apiTokens.create("test-admin", new ApiTokenDtos.CreateRequest(
                "mobile-read", java.util.List.of("nezha:inventory:read"), java.util.List.of(), 7));
        String authorization = "Bearer " + created.secret();

        mvc.perform(get("/api/dashboard").header("Authorization", authorization))
                .andExpect(status().isOk());
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/devices")
                        .header("Authorization", authorization)
                        .with(csrf())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"blocked-by-scope\"}"))
                .andExpect(status().isForbidden());

        apiTokens.revoke("test-admin", created.token().id());
        mvc.perform(get("/api/dashboard").header("Authorization", authorization))
                .andExpect(status().isUnauthorized());
    }

    @Test
    void apiTokenCannotUseSessionOnlyLogoutEndpoint() throws Exception {
        ApiTokenDtos.Created created = apiTokens.create("test-admin", new ApiTokenDtos.CreateRequest(
                "inventory-only", java.util.List.of("nezha:inventory:read"), java.util.List.of(), 7));

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/auth/logout")
                        .header("Authorization", "Bearer " + created.secret()))
                .andExpect(status().isForbidden());
    }

    @Test
    void apiTokenCannotReadBrowserSessionProfile() throws Exception {
        ApiTokenDtos.Created created = apiTokens.create("test-admin", new ApiTokenDtos.CreateRequest(
                "inventory-only", java.util.List.of("nezha:inventory:read"), java.util.List.of(), 7));

        mvc.perform(get("/api/auth/me").header("Authorization", "Bearer " + created.secret()))
                .andExpect(status().isForbidden());
    }

    @Test
    void apiTokenScopeErrorsIdentifyTheRequiredScope() throws Exception {
        ApiTokenDtos.Created serverOnly = apiTokens.create("test-admin", new ApiTokenDtos.CreateRequest(
                "server-only", java.util.List.of("nezha:server:read"), java.util.List.of(), 7));

        mvc.perform(get("/api/client/bootstrap").header("Authorization", "Bearer " + serverOnly.secret()))
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.requiredScope").value("nezha:inventory:read"));

        ApiTokenDtos.Created inventoryOnly = apiTokens.create("test-admin", new ApiTokenDtos.CreateRequest(
                "inventory-only", java.util.List.of("nezha:inventory:read"), java.util.List.of(), 7));

        mvc.perform(get("/api/services").header("Authorization", "Bearer " + inventoryOnly.secret()))
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.requiredScope").value("nezha:service:read"));
    }

    @Test
    void huaweiPushKitInstallationRoutesUseDocumentedScopesAndMethods() throws Exception {
        ApiTokenDtos.Created created = apiTokens.create("test-admin", new ApiTokenDtos.CreateRequest(
                "huawei-push-kit", java.util.List.of(
                        "nezha:push:read", "nezha:push:write", "nezha:push:delete"),
                java.util.List.of(), 7));
        String authorization = "Bearer " + created.secret();

        var response = mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders
                        .post("/api/mobile/installations")
                        .header("Authorization", authorization)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"clientInstallationId":"harmony-test-device","platform":"HARMONYOS","token":"harmony-push-token-0123456789","appVersion":"1.0.0","deviceModel":"test-phone"}
                                """))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.clientInstallationId").value("harmony-test-device"))
                .andExpect(jsonPath("$.tokenSuffix").value("23456789"))
                .andReturn();
        String installationId = mapper.readTree(response.getResponse().getContentAsString()).path("id").asText();

        mvc.perform(get("/api/mobile/installations").header("Authorization", authorization))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[0].id").value(installationId));
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders
                        .patch("/api/mobile/installations/" + installationId + "/preferences")
                        .header("Authorization", authorization)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"minimumSeverity\":\"CRITICAL\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.minimumSeverity").value("CRITICAL"));
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders
                        .post("/api/mobile/installations/" + installationId + "/test")
                        .header("Authorization", authorization))
                .andExpect(status().isServiceUnavailable());
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders
                        .delete("/api/mobile/installations/" + installationId)
                        .header("Authorization", authorization))
                .andExpect(status().isNoContent());

        ApiTokenDtos.Created readOnly = apiTokens.create("test-admin", new ApiTokenDtos.CreateRequest(
                "huawei-push-read", java.util.List.of("nezha:push:read"), java.util.List.of(), 7));
        mvc.perform(get("/api/mobile/installations")
                        .header("Authorization", "Bearer " + readOnly.secret()))
                .andExpect(status().isOk());
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders
                        .post("/api/mobile/installations")
                        .header("Authorization", "Bearer " + readOnly.secret())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"clientInstallationId\":\"read-only-device\",\"platform\":\"HARMONYOS\"}"))
                .andExpect(status().isForbidden());

        ApiTokenDtos.Created noDelete = apiTokens.create("test-admin", new ApiTokenDtos.CreateRequest(
                "huawei-push-write", java.util.List.of("nezha:push:write"), java.util.List.of(), 7));
        var noDeleteResponse = mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders
                        .post("/api/mobile/installations")
                        .header("Authorization", "Bearer " + noDelete.secret())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"clientInstallationId\":\"write-only-device\",\"platform\":\"HARMONYOS\"}"))
                .andExpect(status().isCreated())
                .andReturn();
        String noDeleteId = mapper.readTree(noDeleteResponse.getResponse().getContentAsString()).path("id").asText();
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders
                        .delete("/api/mobile/installations/" + noDeleteId)
                        .header("Authorization", "Bearer " + noDelete.secret()))
                .andExpect(status().isForbidden());
    }

    @Test
    void apiTokenServerWhitelistFiltersInventoryAndDashboard() throws Exception {
        DeviceDtos.Credential allowed = devices.create(new DeviceDtos.CreateRequest("allowed-node", "lab", "tests", "127.0.0.20"));
        DeviceDtos.Credential hidden = devices.create(new DeviceDtos.CreateRequest("hidden-node-for-token", "lab", "tests", "127.0.0.21"));
        ApiTokenDtos.Created created = apiTokens.create("test-admin", new ApiTokenDtos.CreateRequest(
                "scoped-read", java.util.List.of("nezha:inventory:read"), java.util.List.of(allowed.device().id()), 7));

        mvc.perform(get("/api/devices").header("Authorization", "Bearer " + created.secret()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[?(@.id == '" + allowed.device().id() + "')]").isArray())
                .andExpect(jsonPath("$[?(@.id == '" + hidden.device().id() + "')]").doesNotExist());
        mvc.perform(get("/api/dashboard").header("Authorization", "Bearer " + created.secret()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.totalDevices").value(1))
                .andExpect(jsonPath("$.devices[0].id").value(allowed.device().id()));
    }

    @Test
    void apiTokenServerWhitelistBlocksDeviceDetailsAndMetrics() throws Exception {
        DeviceDtos.Credential allowed = devices.create(new DeviceDtos.CreateRequest("metrics-allowed", "lab", "tests", "127.0.0.23"));
        DeviceDtos.Credential hidden = devices.create(new DeviceDtos.CreateRequest("metrics-hidden", "lab", "tests", "127.0.0.24"));
        String report = sampleReport();
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/agent/v1/reports")
                        .header("X-Device-Id", allowed.device().id()).header("X-Agent-Key", allowed.agentKey())
                        .contentType(MediaType.APPLICATION_JSON).content(report))
                .andExpect(status().isAccepted());
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/agent/v1/reports")
                        .header("X-Device-Id", hidden.device().id()).header("X-Agent-Key", hidden.agentKey())
                        .contentType(MediaType.APPLICATION_JSON).content(report))
                .andExpect(status().isAccepted());

        ApiTokenDtos.Created created = apiTokens.create("test-admin", new ApiTokenDtos.CreateRequest(
                "metrics-read", java.util.List.of("nezha:server:read"), java.util.List.of(allowed.device().id()), 7));
        String authorization = "Bearer " + created.secret();

        mvc.perform(get("/api/devices/" + allowed.device().id()).header("Authorization", authorization))
                .andExpect(status().isOk());
        mvc.perform(get("/api/devices/" + allowed.device().id() + "/metrics/latest").header("Authorization", authorization))
                .andExpect(status().isOk());
        mvc.perform(get("/api/devices/" + hidden.device().id()).header("Authorization", authorization))
                .andExpect(status().isForbidden());
        mvc.perform(get("/api/devices/" + hidden.device().id() + "/metrics/latest").header("Authorization", authorization))
                .andExpect(status().isForbidden());
    }

    @Test
    @WithMockUser(username = "operator", roles = "OPERATOR")
    void agentTaskCanBeQueuedClaimedAndCompleted() throws Exception {
        DeviceDtos.Credential credential = devices.create(new DeviceDtos.CreateRequest("task-node", "lab", "tests", "127.0.0.4"));
        grantAccess("operator", UserAccount.Role.OPERATOR, credential.device().id(), false, false, true);
        String body = "{\"deviceId\":\"" + credential.device().id() + "\",\"command\":\"uname\",\"args\":[\"-a\"],\"timeoutSeconds\":10,\"maxOutputBytes\":4096}";

        var created = mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/tasks")
                        .with(csrf()).contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.status").value("QUEUED"))
                .andReturn();
        long taskId = mapper.readTree(created.getResponse().getContentAsString()).get("id").asLong();

        mvc.perform(get("/api/agent/v1/tasks/next")
                        .header("X-Device-Id", credential.device().id())
                        .header("X-Agent-Key", credential.agentKey()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.id").value(taskId))
                .andExpect(jsonPath("$.command").value("uname"));

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/agent/v1/tasks/" + taskId + "/result")
                        .header("X-Device-Id", credential.device().id())
                        .header("X-Agent-Key", credential.agentKey())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"status\":\"SUCCEEDED\",\"exitCode\":0,\"stdout\":\"Linux test\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("SUCCEEDED"))
                .andExpect(jsonPath("$.stdout").value("Linux test"));
    }

    @Test
    @WithMockUser(username = "operator", roles = "OPERATOR")
    void staleRunningAgentTaskIsRecoveredAsTimedOut() throws Exception {
        DeviceDtos.Credential credential = devices.create(new DeviceDtos.CreateRequest("stale-task-node", "lab", "tests", "127.0.0.22"));
        grantAccess("operator", UserAccount.Role.OPERATOR, credential.device().id(), false, false, true);
        String body = "{\"deviceId\":\"" + credential.device().id() + "\",\"command\":\"uname\",\"args\":[],\"timeoutSeconds\":1,\"maxOutputBytes\":4096}";
        var created = mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/tasks")
                        .with(csrf()).contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().isCreated()).andReturn();
        long taskId = mapper.readTree(created.getResponse().getContentAsString()).get("id").asLong();
        mvc.perform(get("/api/agent/v1/tasks/next")
                        .header("X-Device-Id", credential.device().id()).header("X-Agent-Key", credential.agentKey()))
                .andExpect(status().isOk());
        AgentTask task = agentTasks.findById(taskId).orElseThrow();
        task.setStartedAt(Instant.now().minusSeconds(20));
        agentTasks.save(task);
        maintenanceJobs.recoverStaleAgentTasks();
        assertThat(agentTasks.findById(taskId).orElseThrow().getStatus()).isEqualTo(AgentTask.Status.TIMED_OUT);
    }

    @Test
    void mcpRequiresApiTokenAndExposesScopedServerTools() throws Exception {
        DeviceDtos.Credential credential = devices.create(new DeviceDtos.CreateRequest("mcp-node", "lab", "tests", "127.0.0.5"));
        ApiTokenDtos.Created created = apiTokens.create("test-admin", new ApiTokenDtos.CreateRequest(
                "mcp-read-exec", java.util.List.of("nezha:inventory:read", "nezha:server:read", "nezha:server:write", "nezha:server:delete", "nezha:server:exec"), java.util.List.of(credential.device().id()), 7));
        String authorization = "Bearer " + created.secret();

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/mcp")
                        .header("Authorization", authorization).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.result.serverInfo.name").value("guanlan-monitor"));

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/mcp")
                        .header("Authorization", authorization).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"server.list\",\"arguments\":{}}}"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.result.isError").value(false)).andExpect(jsonPath("$.result.structuredContent.servers[0].id").value(credential.device().id()));

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/mcp")
                        .header("Authorization", authorization).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"server.exec\",\"arguments\":{\"server_id\":\"" + credential.device().id() + "\",\"cmd\":\"uname\",\"args\":[\"-a\"]}}}"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.result.isError").value(false)).andExpect(jsonPath("$.result.structuredContent.status").value("QUEUED"));

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/mcp")
                        .header("Authorization", authorization).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"fs.write\",\"arguments\":{\"server_id\":\"" + credential.device().id() + "\",\"path\":\"/tmp/check.txt\",\"content\":\"hello\"}}}"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.result.isError").value(false)).andExpect(jsonPath("$.result.structuredContent.operation").value("FILE_WRITE"))
                .andExpect(jsonPath("$.result.structuredContent.status").value("QUEUED"));

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/mcp")
                        .header("Authorization", authorization).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"fs.delete\",\"arguments\":{\"server_id\":\"" + credential.device().id() + "\",\"path\":\"/tmp/check.txt\"}}}"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.result.isError").value(false));
    }

    @Test
    @WithMockUser(username = "operator", roles = "OPERATOR")
    void ddnsConfigurationCanBeLinkedAndUpdatesOnlyAfterAgentReport() throws Exception {
        var created = mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/ddns")
                        .with(csrf()).contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"name":"dummy-ddns","provider":"DUMMY","domains":["node.example.com"],"method":"GET","enabled":true,"ipv4Enabled":true,"ipv6Enabled":false,"maxRetries":3}
                                """))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.domains[0]").value("node.example.com"))
                .andReturn();
        long ddnsId = mapper.readTree(created.getResponse().getContentAsString()).get("id").asLong();
        DeviceDtos.Credential credential = devices.create(new DeviceDtos.CreateRequest("ddns-node", "lab", "tests", "127.0.0.6"));
        devices.update(credential.device().id(), new DeviceDtos.UpdateRequest("ddns-node", "lab", "tests", "127.0.0.6", true, ddnsId));

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/agent/v1/reports")
                        .header("X-Device-Id", credential.device().id())
                        .header("X-Agent-Key", credential.agentKey())
                        .header("X-Real-IP", "203.0.113.7")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(sampleReport()))
                .andExpect(status().isAccepted());

        Device updated = null;
        for (int attempt = 0; attempt < 30; attempt++) {
            updated = deviceRepository.findById(credential.device().id()).orElseThrow();
            if ("203.0.113.7".equals(updated.getLastDdnsIpv4())) break;
            Thread.sleep(100);
        }
        assertThat(updated).isNotNull();
        assertThat(updated.getLastDdnsIpv4()).isEqualTo("203.0.113.7");
        assertThat(ddnsConfigs.findById(ddnsId).orElseThrow().getLastStatus()).isEqualTo("SUCCEEDED");
    }

    private void grantAccess(String username, UserAccount.Role role, String deviceId,
                             boolean manage, boolean alert, boolean task) {
        UserAccount user = userAccounts.findByUsernameIgnoreCase(username).orElseGet(() -> {
            UserAccount created = new UserAccount();
            created.setUsername(username);
            created.setDisplayName(username);
            created.setPasswordHash(passwordEncoder.encode("Test-only-password-123"));
            created.setRole(role);
            created.setEnabled(true);
            return userAccounts.save(created);
        });
        UserDevicePermission permission = devicePermissions
                .findByUserUsernameIgnoreCaseAndDeviceId(username, deviceId)
                .orElseGet(UserDevicePermission::new);
        permission.setUser(user);
        permission.setDevice(deviceRepository.findById(deviceId).orElseThrow());
        permission.setCanView(true);
        permission.setCanManage(manage);
        permission.setCanAlert(alert);
        permission.setCanTask(task);
        devicePermissions.save(permission);
    }

    @Test
    void bufferedMetricReplayKeepsTheCurrentSnapshotLatestAndIsIdempotent() throws Exception {
        DeviceDtos.Credential credential = devices.create(new DeviceDtos.CreateRequest("replay-node", "lab", "tests", "127.0.0.33"));
        Instant current = Instant.now().minusSeconds(1).truncatedTo(java.time.temporal.ChronoUnit.MICROS);
        Instant historical = current.minus(Duration.ofMinutes(10));

        reportMetric(credential, sampleReportAt(current, "current-host"));
        reportMetric(credential, sampleReportAt(historical, "historical-host"));
        reportMetric(credential, sampleReportAt(current, "current-host"));

        assertThat(metricSnapshots.countByDeviceId(credential.device().id())).isEqualTo(2);
        assertThat(metricSnapshots.findTopByDeviceIdOrderByCollectedAtDesc(credential.device().id()).orElseThrow().getCollectedAt()).isEqualTo(current);
        assertThat(deviceRepository.findById(credential.device().id()).orElseThrow().getHostname()).isEqualTo("current-host");
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

    private String sampleReportAt(Instant collectedAt, String hostname) throws Exception {
        com.fasterxml.jackson.databind.node.ObjectNode report = (com.fasterxml.jackson.databind.node.ObjectNode) mapper.readTree(sampleReport());
        report.put("collectedAt", collectedAt.toString());
        ((com.fasterxml.jackson.databind.node.ObjectNode) report.path("host")).put("hostname", hostname);
        return mapper.writeValueAsString(report);
    }

    private void reportMetric(DeviceDtos.Credential credential, String report) throws Exception {
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/agent/v1/reports")
                        .header("X-Device-Id", credential.device().id())
                        .header("X-Agent-Key", credential.agentKey())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(report))
                .andExpect(status().isAccepted());
    }
}
