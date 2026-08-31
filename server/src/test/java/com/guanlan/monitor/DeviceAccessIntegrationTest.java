package com.guanlan.monitor;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.api.dto.ApiTokenDtos;
import com.guanlan.monitor.api.dto.AlertDtos;
import com.guanlan.monitor.api.dto.DeviceDtos;
import com.guanlan.monitor.api.dto.MaintenanceDtos;
import com.guanlan.monitor.api.dto.UserDtos;
import com.guanlan.monitor.domain.AlertRule;
import com.guanlan.monitor.domain.MaintenanceWindow;
import com.guanlan.monitor.domain.UserAccount;
import com.guanlan.monitor.repository.UserAccountRepository;
import com.guanlan.monitor.service.ApiTokenService;
import com.guanlan.monitor.service.AlertService;
import com.guanlan.monitor.service.DeviceAccessService;
import com.guanlan.monitor.service.DeviceService;
import com.guanlan.monitor.service.MaintenanceWindowService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.user;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
@Transactional
class DeviceAccessIntegrationTest {
    @Autowired MockMvc mvc;
    @Autowired DeviceService devices;
    @Autowired DeviceAccessService access;
    @Autowired UserAccountRepository users;
    @Autowired ApiTokenService tokens;
    @Autowired AlertService alerts;
    @Autowired MaintenanceWindowService maintenance;

    @Test
    void viewerCannotReadUnassignedDeviceThroughDirectOrAggregateEndpoints() throws Exception {
        UserAccount viewer = account("device-scope-viewer", UserAccount.Role.VIEWER);
        var visible = device("scope-visible");
        var hidden = device("scope-hidden");
        replace(viewer, permission(visible, true, false, false, false));

        var requestUser = user(viewer.getUsername()).roles("VIEWER");
        mvc.perform(get("/api/devices").with(requestUser))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[?(@.id == '" + visible + "')]").isArray())
                .andExpect(jsonPath("$[?(@.id == '" + hidden + "')]").doesNotExist());
        mvc.perform(get("/api/devices/" + visible).with(requestUser)).andExpect(status().isOk());
        mvc.perform(get("/api/devices/" + hidden).with(requestUser)).andExpect(status().isForbidden());
        mvc.perform(get("/api/devices/" + hidden + "/metrics/latest").with(requestUser)).andExpect(status().isForbidden());
        mvc.perform(get("/api/dashboard").with(requestUser))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.totalDevices").value(1));
        mvc.perform(get("/api/reports/summary").with(requestUser))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.totalDevices").value(1));
        mvc.perform(get("/api/topology").with(requestUser))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.nodes[?(@.id == '" + hidden + "')]").doesNotExist());
    }

    @Test
    void manageAlertAndTaskPermissionsAreIndependent() throws Exception {
        UserAccount operator = account("device-scope-operator", UserAccount.Role.OPERATOR);
        String viewOnly = device("view-only");
        String managed = device("managed");
        replace(operator,
                permission(viewOnly, true, false, true, false),
                permission(managed, true, true, false, true));
        var authentication = UsernamePasswordAuthenticationToken.authenticated(operator.getUsername(), "",
                List.of(new SimpleGrantedAuthority("ROLE_OPERATOR")));

        assertThat(access.canView(authentication, viewOnly)).isTrue();
        assertThat(access.canManage(authentication, viewOnly)).isFalse();
        assertThat(access.canAlert(authentication, viewOnly)).isTrue();
        assertThat(access.canTask(authentication, viewOnly)).isFalse();
        assertThat(access.canManage(authentication, managed)).isTrue();
        assertThat(access.canAlert(authentication, managed)).isFalse();
        assertThat(access.canTask(authentication, managed)).isTrue();
        assertThatThrownBy(() -> access.requireManage(authentication, viewOnly)).isInstanceOf(ApiException.class);

        var requestUser = user(operator.getUsername()).roles("OPERATOR");
        mvc.perform(post("/api/devices/" + viewOnly + "/notes").with(requestUser).with(csrf())
                        .contentType(MediaType.APPLICATION_JSON).content("{\"content\":\"blocked\"}"))
                .andExpect(status().isForbidden());
        mvc.perform(post("/api/devices/" + managed + "/notes").with(requestUser).with(csrf())
                        .contentType(MediaType.APPLICATION_JSON).content("{\"content\":\"allowed\"}"))
                .andExpect(status().isCreated());
        mvc.perform(post("/api/tasks").with(requestUser).with(csrf()).contentType(MediaType.APPLICATION_JSON)
                        .content(taskBody(viewOnly)))
                .andExpect(status().isForbidden());
        mvc.perform(post("/api/tasks").with(requestUser).with(csrf()).contentType(MediaType.APPLICATION_JSON)
                        .content(taskBody(managed)))
                .andExpect(status().isCreated());
    }

    @Test
    void administratorRemainsUnrestrictedWithoutPermissionRows() throws Exception {
        String deviceId = device("admin-visible");
        mvc.perform(get("/api/devices/" + deviceId).with(user("scope-admin").roles("ADMIN")))
                .andExpect(status().isOk());
    }

    @Test
    void apiTokenUsesIntersectionOfOwnerPermissionsAndServerWhitelist() throws Exception {
        UserAccount operator = account("device-token-operator", UserAccount.Role.OPERATOR);
        String assigned = device("token-assigned");
        String unassigned = device("token-unassigned");
        replace(operator, permission(assigned, true, false, false, false));
        ApiTokenDtos.Created token = tokens.create(operator.getUsername(), new ApiTokenDtos.CreateRequest(
                "intersection", List.of("nezha:inventory:read", "nezha:server:read"),
                List.of(assigned, unassigned), 7));
        String bearer = "Bearer " + token.secret();

        mvc.perform(get("/api/devices").header("Authorization", bearer))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[?(@.id == '" + assigned + "')]").isArray())
                .andExpect(jsonPath("$[?(@.id == '" + unassigned + "')]").doesNotExist());
        mvc.perform(get("/api/devices/" + assigned).header("Authorization", bearer)).andExpect(status().isOk());
        mvc.perform(get("/api/devices/" + unassigned).header("Authorization", bearer)).andExpect(status().isForbidden());
    }

    @Test
    void administratorTokenReportsFullPermissionsWithinServerWhitelist() throws Exception {
        UserAccount admin = account("device-token-admin", UserAccount.Role.ADMIN);
        String allowed = device("admin-token-allowed");
        String excluded = device("admin-token-excluded");
        ApiTokenDtos.Created token = tokens.create(admin.getUsername(), new ApiTokenDtos.CreateRequest(
                "admin-whitelist", List.of("nezha:inventory:read"), List.of(allowed), 7));

        mvc.perform(get("/api/device-access/me").header("Authorization", "Bearer " + token.secret()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[?(@.deviceId == '" + allowed + "')].canView").value(true))
                .andExpect(jsonPath("$[?(@.deviceId == '" + allowed + "')].canManage").value(true))
                .andExpect(jsonPath("$[?(@.deviceId == '" + allowed + "')].canAlert").value(true))
                .andExpect(jsonPath("$[?(@.deviceId == '" + allowed + "')].canTask").value(true))
                .andExpect(jsonPath("$[?(@.deviceId == '" + excluded + "')]").doesNotExist());
    }

    @Test
    void maintenanceWindowUsesRuleDeviceAsItsEffectivePermissionScope() throws Exception {
        UserAccount operator = account("maintenance-scope-operator", UserAccount.Role.OPERATOR);
        String allowed = device("maintenance-allowed");
        String hidden = device("maintenance-hidden");
        replace(operator, permission(allowed, true, false, true, false));
        AlertDtos.RuleView hiddenRule = alerts.createRule(new AlertDtos.RuleRequest(
                "hidden-device-rule", hidden, AlertRule.Metric.CPU_USAGE, 90,
                AlertRule.Severity.WARNING, true, null));
        MaintenanceDtos.WindowView hiddenWindow = maintenance.create(new MaintenanceDtos.WindowRequest(
                "hidden-rule-window", null, hiddenRule.id(), Instant.parse("2026-09-01T00:00:00Z"),
                Instant.parse("2026-09-01T01:00:00Z"), "UTC", MaintenanceWindow.Recurrence.NONE,
                null, null, true));
        var requestUser = user(operator.getUsername()).roles("OPERATOR");

        mvc.perform(get("/api/maintenance-windows").with(requestUser))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[?(@.id == " + hiddenWindow.id() + ")]").doesNotExist());
        mvc.perform(post("/api/maintenance-windows").with(requestUser).with(csrf())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(maintenanceBody(hiddenRule.id())))
                .andExpect(status().isForbidden());
    }

    private UserAccount account(String username, UserAccount.Role role) {
        UserAccount account = new UserAccount();
        account.setUsername(username);
        account.setDisplayName(username);
        account.setPasswordHash("test-only-password-hash");
        account.setRole(role);
        account.setEnabled(true);
        return users.save(account);
    }

    private String device(String name) {
        return devices.create(new DeviceDtos.CreateRequest(name, "lab", "tests", "127.0.0.1")).device().id();
    }

    private void replace(UserAccount user, UserDtos.DevicePermissionItem... permissions) {
        access.replace(user.getId(), new UserDtos.DevicePermissionRequest(List.of(permissions)));
    }

    private UserDtos.DevicePermissionItem permission(String deviceId, boolean view, boolean manage,
                                                     boolean alert, boolean task) {
        return new UserDtos.DevicePermissionItem(deviceId, view, manage, alert, task);
    }

    private String taskBody(String deviceId) {
        return "{\"deviceId\":\"" + deviceId + "\",\"command\":\"uname\",\"args\":[],\"timeoutSeconds\":10,\"maxOutputBytes\":4096}";
    }

    private String maintenanceBody(Long ruleId) {
        return "{\"name\":\"blocked\",\"deviceId\":null,\"ruleId\":" + ruleId
                + ",\"startsAt\":\"2026-09-01T00:00:00Z\",\"endsAt\":\"2026-09-01T01:00:00Z\""
                + ",\"timezone\":\"UTC\",\"recurrence\":\"NONE\",\"repeatUntil\":null,\"reason\":null,\"enabled\":true}";
    }
}
