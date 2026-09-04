package com.guanlan.monitor.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.api.dto.AgentRolloutDtos;
import com.guanlan.monitor.api.dto.UserDtos;
import com.guanlan.monitor.domain.AgentRollout;
import com.guanlan.monitor.domain.AgentRolloutMember;
import com.guanlan.monitor.domain.AgentTask;
import com.guanlan.monitor.domain.Device;
import com.guanlan.monitor.domain.MaintenanceWindow;
import com.guanlan.monitor.domain.UserAccount;
import com.guanlan.monitor.repository.AgentTaskRepository;
import com.guanlan.monitor.repository.DeviceRepository;
import com.guanlan.monitor.repository.MaintenanceWindowRepository;
import com.guanlan.monitor.repository.UserAccountRepository;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;

import java.time.Instant;
import java.util.*;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.user;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@SpringBootTest(properties = "spring.task.scheduling.enabled=false")
@AutoConfigureMockMvc
@ActiveProfiles("test")
class AgentRolloutServiceIntegrationTest {
    @Autowired AgentRolloutService rollouts;
    @Autowired AgentTaskRepository tasks;
    @Autowired DeviceRepository devices;
    @Autowired MaintenanceWindowRepository maintenanceWindows;
    @Autowired UserAccountRepository users;
    @Autowired DeviceAccessService access;
    @Autowired ObjectMapper mapper;
    @Autowired MockMvc mvc;

    @Test
    @WithMockUser(username = "admin", roles = "ADMIN")
    void updateTaskUsesClosedPayloadAndFixedCommand() throws Exception {
        Device device = device("payload", "v1.20.13");
        AgentRolloutDtos.View rollout = createRollout(List.of(device), 100, 1, 1, 0, 50);
        rollout = rollouts.start(rollout.id(), null);
        AgentRolloutDtos.MemberView member = rollout.members().getFirst();

        String invalid = mapper.writeValueAsString(Map.of(
                "deviceId", device.getId(), "action", "update", "version", "v1.20.14",
                "rolloutId", rollout.id(), "memberId", member.id(), "command", "curl example.invalid"));
        mvc.perform(post("/api/tasks/update").with(csrf()).contentType(MediaType.APPLICATION_JSON).content(invalid))
                .andExpect(status().isBadRequest());
        mvc.perform(post("/api/tasks").with(csrf()).contentType(MediaType.APPLICATION_JSON)
                        .content(mapper.writeValueAsString(Map.of(
                                "deviceId", device.getId(), "command", "agent.update", "args", List.of(),
                                "timeoutSeconds", 30, "maxOutputBytes", 4096))))
                .andExpect(status().isBadRequest());

        String request = mapper.writeValueAsString(Map.of(
                "deviceId", device.getId(), "action", "update", "version", "v1.20.14",
                "rolloutId", rollout.id(), "memberId", member.id()));
        long taskId = mapper.readTree(mvc.perform(post("/api/tasks/update").with(csrf())
                        .contentType(MediaType.APPLICATION_JSON).content(request))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.operation").value("AGENT_UPDATE"))
                .andExpect(jsonPath("$.command").value("agent.update"))
                .andReturn().getResponse().getContentAsString()).path("id").asLong();

        AgentTask task = tasks.findById(taskId).orElseThrow();
        JsonNode payload = mapper.readTree(task.getPayloadJson());
        assertThat(task.getArgsJson()).isEqualTo("[]");
        assertThat(payload.size()).isEqualTo(4);
        assertThat(iterable(payload.fieldNames())).containsExactlyInAnyOrder(
                "action", "version", "rolloutId", "memberId");
        assertThat(payload.path("action").asText()).isEqualTo("update");
        assertThat(payload.path("version").asText()).isEqualTo("v1.20.14");
    }

    @Test
    void groupingIsDeterministicAcrossRollouts() {
        List<Device> deviceList = devices(12, "deterministic", "v1.20.13");
        AgentRolloutDtos.View first = createRollout(deviceList, 20, 4, 2, 0, 50);
        AgentRolloutDtos.View second = createRollout(deviceList, 20, 4, 2, 0, 50);

        assertThat(assignments(first)).isEqualTo(assignments(second));
        assertThat(first.members().stream().filter(member -> member.ring() == 0)).hasSize(3);
        assertThat(first.members()).extracting(AgentRolloutDtos.MemberView::ring)
                .allMatch(ring -> ring >= 0 && ring < 4);
    }

    @Test
    void maxConcurrencyAndRingBarrierWaitForVersionReport() {
        List<Device> deviceList = devices(4, "rings", "v1.20.13");
        AgentRolloutDtos.View rollout = createRollout(deviceList, 25, 3, 1, 0, 100);
        rollouts.start(rollout.id(), null);
        Instant tick = Instant.now().plusSeconds(1);

        rollouts.advance(rollout.id(), tick);
        AgentRolloutDtos.View queued = rollouts.getInternal(rollout.id());
        assertThat(queued.rollbackTotal()).isNull();
        AgentRolloutDtos.MemberView canary = queued.members().stream()
                .filter(member -> member.status() == AgentRolloutMember.Status.QUEUED).findFirst().orElseThrow();
        assertThat(queued.currentRing()).isZero();
        assertThat(inFlight(queued)).isEqualTo(1);

        AgentTask task = tasks.findById(canary.taskId()).orElseThrow();
        task.setStatus(AgentTask.Status.SUCCEEDED);
        task.setFinishedAt(tick.plusSeconds(1));
        tasks.saveAndFlush(task);
        rollouts.advance(rollout.id(), tick.plusSeconds(2));
        AgentRolloutDtos.View accepted = rollouts.getInternal(rollout.id());
        assertThat(member(accepted, canary.id()).status()).isEqualTo(AgentRolloutMember.Status.ACCEPTED);
        assertThat(accepted.currentRing()).isZero();
        assertThat(tasksFor(rollout.id())).hasSize(1);

        Device canaryDevice = devices.findById(canary.deviceId()).orElseThrow();
        canaryDevice.setAgentVersion("v1.20.14");
        canaryDevice.setLastSeenAt(member(accepted, canary.id()).queuedAt());
        devices.saveAndFlush(canaryDevice);
        rollouts.advance(rollout.id(), tick.plusSeconds(3));

        AgentRolloutDtos.View nextRing = rollouts.getInternal(rollout.id());
        assertThat(member(nextRing, canary.id()).status()).isEqualTo(AgentRolloutMember.Status.CONFIRMED);
        assertThat(nextRing.currentRing()).isEqualTo(1);
        assertThat(inFlight(nextRing)).isEqualTo(1);
        assertThat(nextRing.members().stream()
                .filter(value -> value.ring() == 1 && value.status() == AgentRolloutMember.Status.PENDING))
                .hasSize(1);
    }

    @Test
    void taskFailurePausesAtConfiguredThreshold() {
        Device device = device("failure", "v1.20.13");
        AgentRolloutDtos.View rollout = createRollout(List.of(device), 100, 1, 1, 0, 50);
        rollouts.start(rollout.id(), null);
        Instant tick = Instant.now().plusSeconds(1);
        rollouts.advance(rollout.id(), tick);
        AgentRolloutDtos.MemberView queued = rollouts.getInternal(rollout.id()).members().getFirst();

        AgentTask task = tasks.findById(queued.taskId()).orElseThrow();
        task.setStatus(AgentTask.Status.FAILED);
        task.setFinishedAt(tick.plusSeconds(1));
        task.setError("installer rejected package");
        tasks.saveAndFlush(task);
        rollouts.advance(rollout.id(), tick.plusSeconds(2));

        AgentRolloutDtos.View paused = rollouts.getInternal(rollout.id());
        assertThat(paused.status()).isEqualTo(AgentRollout.Status.PAUSED);
        assertThat(paused.statusReason()).contains("50%");
        assertThat(paused.members().getFirst().status()).isEqualTo(AgentRolloutMember.Status.FAILED);

        assertThat(rollouts.resume(rollout.id(), "acknowledged").status()).isEqualTo(AgentRollout.Status.RUNNING);
        rollouts.advance(rollout.id(), tick.plusSeconds(3));
        assertThat(rollouts.getInternal(rollout.id()).status()).isEqualTo(AgentRollout.Status.FAILED);
    }

    @Test
    void rollbackTargetsOnlyConfirmedMembersAndNeedsASecondVersionReport() {
        Device confirmedDevice = device("rollback-confirmed", "v1.20.13");
        Device failedDevice = device("rollback-failed", "v1.20.13");
        AgentRolloutDtos.View rollout = createRollout(
                List.of(confirmedDevice, failedDevice), 100, 1, 2, 0, 50);
        rollouts.start(rollout.id(), null);
        Instant tick = Instant.now().plusSeconds(1);
        rollouts.advance(rollout.id(), tick);
        AgentRolloutDtos.View queued = rollouts.getInternal(rollout.id());

        AgentRolloutDtos.MemberView confirmedMember = queued.members().stream()
                .filter(member -> member.deviceId().equals(confirmedDevice.getId())).findFirst().orElseThrow();
        AgentRolloutDtos.MemberView failedMember = queued.members().stream()
                .filter(member -> member.deviceId().equals(failedDevice.getId())).findFirst().orElseThrow();
        confirmedDevice.setAgentVersion("v1.20.14");
        confirmedDevice.setLastSeenAt(confirmedMember.queuedAt().plusMillis(1));
        devices.saveAndFlush(confirmedDevice);
        AgentTask failedTask = tasks.findById(failedMember.taskId()).orElseThrow();
        failedTask.setStatus(AgentTask.Status.FAILED);
        failedTask.setFinishedAt(tick.plusSeconds(1));
        tasks.saveAndFlush(failedTask);
        rollouts.advance(rollout.id(), tick.plusSeconds(2));

        AgentRolloutDtos.View paused = rollouts.getInternal(rollout.id());
        assertThat(memberByDevice(paused, confirmedDevice.getId()).status())
                .isEqualTo(AgentRolloutMember.Status.CONFIRMED);
        assertThat(paused.status()).isEqualTo(AgentRollout.Status.PAUSED);

        AgentRolloutDtos.View rollingBack = rollouts.rollback(rollout.id(), "canary failed");
        assertThat(rollingBack.rollbackTotal()).isEqualTo(1);
        assertThat(memberByDevice(rollingBack, confirmedDevice.getId()).status())
                .isEqualTo(AgentRolloutMember.Status.ROLLBACK_PENDING);
        assertThat(memberByDevice(rollingBack, failedDevice.getId()).status())
                .isEqualTo(AgentRolloutMember.Status.FAILED);
        rollouts.advance(rollout.id(), tick.plusSeconds(3));
        AgentRolloutDtos.MemberView rollbackQueued = memberByDevice(rollouts.getInternal(rollout.id()), confirmedDevice.getId());
        JsonNode rollbackPayload = payload(rollbackQueued.taskId());
        assertThat(rollbackPayload.path("action").asText()).isEqualTo("rollback");
        assertThat(rollbackPayload.path("version").asText()).isEqualTo("v1.20.13");

        AgentTask rollbackTask = tasks.findById(rollbackQueued.taskId()).orElseThrow();
        rollbackTask.setStatus(AgentTask.Status.SUCCEEDED);
        rollbackTask.setFinishedAt(tick.plusSeconds(4));
        tasks.saveAndFlush(rollbackTask);
        rollouts.advance(rollout.id(), tick.plusSeconds(5));
        assertThat(memberByDevice(rollouts.getInternal(rollout.id()), confirmedDevice.getId()).status())
                .isEqualTo(AgentRolloutMember.Status.ROLLBACK_ACCEPTED);

        confirmedDevice.setAgentVersion("v1.20.13");
        confirmedDevice.setLastSeenAt(rollbackQueued.queuedAt().plusMillis(1));
        devices.saveAndFlush(confirmedDevice);
        rollouts.advance(rollout.id(), tick.plusSeconds(6));
        AgentRolloutDtos.View rolledBack = rollouts.getInternal(rollout.id());
        assertThat(rolledBack.status()).isEqualTo(AgentRollout.Status.ROLLED_BACK);
        assertThat(rolledBack.rollbackTotal()).isEqualTo(1);
        assertThat(memberByDevice(rolledBack, confirmedDevice.getId()).status())
                .isEqualTo(AgentRolloutMember.Status.ROLLBACK_CONFIRMED);
    }

    @Test
    void rollbackTracksRunningForwardTaskUntilLateVersionReport() {
        assertRollbackTracksLateForwardUpdate(AgentTask.Status.RUNNING,
                AgentRolloutMember.Status.QUEUED);
    }

    @Test
    void rollbackTracksSucceededForwardTaskUntilLateVersionReport() {
        assertRollbackTracksLateForwardUpdate(AgentTask.Status.SUCCEEDED,
                AgentRolloutMember.Status.ACCEPTED);
    }

    @Test
    void rollbackTracksClaimedTimedOutForwardTaskUntilLateVersionReport() {
        assertRollbackTracksLateForwardUpdate(AgentTask.Status.TIMED_OUT,
                AgentRolloutMember.Status.ACCEPTED);
    }

    @Test
    void rollbackRevisitsHigherRingAfterLateForwardVersionReport() {
        List<Device> deviceList = devices(2, "late-higher-ring", "v1.20.13");
        AgentRolloutDtos.View rollout = createRollout(deviceList, 50, 2, 2, 0, 100);
        rollouts.start(rollout.id(), null);
        Instant tick = Instant.now().plusSeconds(1);
        rollouts.advance(rollout.id(), tick);
        AgentRolloutDtos.View firstRing = rollouts.getInternal(rollout.id());
        AgentRolloutDtos.MemberView ringZero = firstRing.members().stream()
                .filter(member -> member.ring() == 0).findFirst().orElseThrow();
        Device ringZeroDevice = devices.findById(ringZero.deviceId()).orElseThrow();
        ringZeroDevice.setAgentVersion("v1.20.14");
        ringZeroDevice.setLastSeenAt(ringZero.queuedAt().plusMillis(1));
        devices.saveAndFlush(ringZeroDevice);
        rollouts.advance(rollout.id(), tick.plusSeconds(1));

        AgentRolloutDtos.View secondRing = rollouts.getInternal(rollout.id());
        AgentRolloutDtos.MemberView ringOne = secondRing.members().stream()
                .filter(member -> member.ring() == 1).findFirst().orElseThrow();
        AgentTask lateForwardTask = tasks.findById(ringOne.taskId()).orElseThrow();
        lateForwardTask.setStatus(AgentTask.Status.RUNNING);
        lateForwardTask.setStartedAt(ringOne.queuedAt().plusMillis(1));
        tasks.saveAndFlush(lateForwardTask);

        AgentRolloutDtos.View rollingBack = rollouts.rollback(rollout.id(), "higher ring is still applying");
        assertThat(rollingBack.currentRing()).isZero();
        assertThat(member(rollingBack, ringOne.id()).status()).isEqualTo(AgentRolloutMember.Status.QUEUED);
        rollouts.advance(rollout.id(), tick.plusSeconds(2));
        AgentRolloutDtos.MemberView ringZeroRollback = member(rollouts.getInternal(rollout.id()), ringZero.id());
        ringZeroDevice.setAgentVersion("v1.20.13");
        ringZeroDevice.setLastSeenAt(ringZeroRollback.queuedAt().plusMillis(1));
        devices.saveAndFlush(ringZeroDevice);
        rollouts.advance(rollout.id(), tick.plusSeconds(3));
        assertThat(rollouts.getInternal(rollout.id()).status()).isEqualTo(AgentRollout.Status.ROLLING_BACK);

        Device ringOneDevice = devices.findById(ringOne.deviceId()).orElseThrow();
        ringOneDevice.setAgentVersion("v1.20.14");
        ringOneDevice.setLastSeenAt(ringOne.queuedAt().plusSeconds(1));
        devices.saveAndFlush(ringOneDevice);
        rollouts.advance(rollout.id(), tick.plusSeconds(4));

        AgentRolloutDtos.View revisited = rollouts.getInternal(rollout.id());
        assertThat(revisited.currentRing()).isEqualTo(1);
        assertThat(member(revisited, ringOne.id()).status())
                .isEqualTo(AgentRolloutMember.Status.ROLLBACK_QUEUED);
        assertThat(payload(member(revisited, ringOne.id()).taskId()).path("action").asText())
                .isEqualTo("rollback");
    }

    @Test
    void concurrentStartsCannotReserveTheSameDevice() throws Exception {
        Device device = device("concurrent-rollout", "v1.20.13");
        AgentRolloutDtos.View first = createRollout(List.of(device), 100, 1, 1, 0, 50);
        AgentRolloutDtos.View second = createRollout(List.of(device), 100, 1, 1, 0, 50);
        CountDownLatch ready = new CountDownLatch(2);
        CountDownLatch start = new CountDownLatch(1);

        try (var executor = Executors.newFixedThreadPool(2)) {
            List<java.util.concurrent.Future<Boolean>> attempts = List.of(first, second).stream()
                    .map(candidate -> executor.submit(() -> {
                        ready.countDown();
                        start.await(10, TimeUnit.SECONDS);
                        try {
                            rollouts.start(candidate.id(), null);
                            return true;
                        } catch (ApiException exception) {
                            assertThat(exception.getMessage()).contains("其他活动中的 Agent rollout");
                            return false;
                        }
                    })).toList();
            assertThat(ready.await(10, TimeUnit.SECONDS)).isTrue();
            start.countDown();
            int successes = 0;
            for (var attempt : attempts) {
                if (attempt.get(20, TimeUnit.SECONDS)) successes++;
            }
            assertThat(successes).isEqualTo(1);
        }

        assertThat(List.of(rollouts.getInternal(first.id()).status(), rollouts.getInternal(second.id()).status()))
                .containsExactlyInAnyOrder(AgentRollout.Status.RUNNING, AgentRollout.Status.DRAFT);
    }

    @Test
    void startRejectsDeviceVersionChangedSinceDraftCreation() {
        Device device = device("draft-version-drift", "v1.20.13");
        AgentRolloutDtos.View rollout = createRollout(List.of(device), 100, 1, 1, 0, 50);
        device.setAgentVersion("v1.20.15");
        devices.saveAndFlush(device);

        assertThatThrownBy(() -> rollouts.start(rollout.id(), null))
                .isInstanceOf(ApiException.class).hasMessageContaining("请重新创建 rollout");
        assertThat(rollouts.getInternal(rollout.id()).status()).isEqualTo(AgentRollout.Status.DRAFT);
        assertThat(tasksFor(rollout.id())).isEmpty();
    }

    @Test
    void completedOldRolloutCannotDowngradeDeviceThatMovedToANewerVersion() {
        Device device = device("old-rollout", "v1.20.13");
        AgentRolloutDtos.View rollout = completeForwardRollout(device);
        device.setAgentVersion("v1.20.15");
        device.setLastSeenAt(Instant.now().plusSeconds(10));
        devices.saveAndFlush(device);

        assertThatThrownBy(() -> rollouts.rollback(rollout.id(), "old rollout"))
                .isInstanceOf(ApiException.class).hasMessageContaining("没有当前仍处于目标版本");
        assertThat(tasksFor(rollout.id())).hasSize(1);
        assertThat(rollouts.getInternal(rollout.id()).status()).isEqualTo(AgentRollout.Status.SUCCEEDED);
    }

    @Test
    void rollbackRechecksVersionImmediatelyBeforeTaskCreation() {
        Device device = device("rollback-dispatch-drift", "v1.20.13");
        AgentRolloutDtos.View rollout = completeForwardRollout(device);
        AgentRolloutDtos.View rollingBack = rollouts.rollback(rollout.id(), "verify dispatch guard");
        assertThat(rollingBack.members().getFirst().status())
                .isEqualTo(AgentRolloutMember.Status.ROLLBACK_PENDING);

        device.setAgentVersion("v1.20.15");
        device.setLastSeenAt(Instant.now().plusSeconds(20));
        devices.saveAndFlush(device);
        rollouts.advance(rollout.id(), Instant.now().plusSeconds(21));

        AgentRolloutDtos.View rejected = rollouts.getInternal(rollout.id());
        assertThat(rejected.members().getFirst().status()).isEqualTo(AgentRolloutMember.Status.ROLLBACK_FAILED);
        assertThat(rejected.members().getFirst().error()).contains("拒绝降级回滚");
        assertThat(tasksFor(rollout.id())).hasSize(1);
        rollouts.advance(rollout.id(), Instant.now().plusSeconds(22));
        assertThat(rollouts.getInternal(rollout.id()).status()).isEqualTo(AgentRollout.Status.FAILED);
    }

    @Test
    void rollbackTotalRemainsStableAndPermissionScopedWhenFullRollbackIsCanceled() throws Exception {
        List<Device> deviceList = devices(2, "rollback-cancel", "v1.20.13");
        AgentRolloutDtos.View rollout = createRollout(deviceList, 100, 1, 2, 0, 50);
        rollouts.start(rollout.id(), null);
        Instant tick = Instant.now().plusSeconds(1);
        rollouts.advance(rollout.id(), tick);
        AgentRolloutDtos.View queued = rollouts.getInternal(rollout.id());
        assertThat(queued.rollbackTotal()).isNull();

        for (AgentRolloutDtos.MemberView member : queued.members()) {
            Device upgraded = devices.findById(member.deviceId()).orElseThrow();
            upgraded.setAgentVersion("v1.20.14");
            upgraded.setLastSeenAt(member.queuedAt().plusMillis(1));
            devices.saveAndFlush(upgraded);
        }
        rollouts.advance(rollout.id(), tick.plusSeconds(1));

        AgentRolloutDtos.View rollingBack = rollouts.rollback(rollout.id(), "verify stable total");
        assertThat(rollingBack.rollbackTotal()).isEqualTo(2);
        assertThat(rollingBack.members()).extracting(AgentRolloutDtos.MemberView::status)
                .containsOnly(AgentRolloutMember.Status.ROLLBACK_PENDING);

        rollouts.advance(rollout.id(), tick.plusSeconds(2));
        AgentRolloutDtos.View canceled = rollouts.cancel(rollout.id(), "stop rollback");

        assertThat(canceled.status()).isEqualTo(AgentRollout.Status.CANCELED);
        assertThat(canceled.rollbackTotal()).isEqualTo(2);
        assertThat(canceled.members()).extracting(AgentRolloutDtos.MemberView::status)
                .containsOnly(AgentRolloutMember.Status.CANCELED);
        assertThat(rollouts.getInternal(rollout.id()).rollbackTotal()).isEqualTo(2);

        Device visible = deviceList.getFirst();
        UserAccount viewer = account("rollback-total-viewer", UserAccount.Role.VIEWER);
        UserAccount operator = account("rollback-total-operator", UserAccount.Role.OPERATOR);
        access.replace(viewer.getId(), new UserDtos.DevicePermissionRequest(List.of(
                new UserDtos.DevicePermissionItem(visible.getId(), true, false, false, false))));
        access.replace(operator.getId(), new UserDtos.DevicePermissionRequest(List.of(
                new UserDtos.DevicePermissionItem(visible.getId(), true, false, false, false))));

        for (UserAccount account : List.of(viewer, operator)) {
            mvc.perform(get("/api/agent-rollouts/" + rollout.id())
                            .with(user(account.getUsername()).roles(account.getRole().name())))
                    .andExpect(status().isOk())
                    .andExpect(jsonPath("$.rollbackTotal").value(1))
                    .andExpect(jsonPath("$.members.length()").value(1))
                    .andExpect(jsonPath("$.members[0].deviceId").value(visible.getId()));
        }
    }

    @Test
    void inactiveMaintenanceWindowBlocksDispatch() {
        Device device = device("window", "v1.20.13");
        MaintenanceWindow window = new MaintenanceWindow();
        window.setName("tomorrow");
        window.setStartsAt(Instant.now().plusSeconds(86_400));
        window.setEndsAt(Instant.now().plusSeconds(90_000));
        window.setTimezone("UTC");
        window.setEnabled(true);
        maintenanceWindows.saveAndFlush(window);
        AgentRolloutDtos.View rollout = rollouts.create(new AgentRolloutDtos.CreateRequest(
                "v1.20.14", List.of(device.getId()), window.getId(), 100, 1, 1, 0, 50, 30), "test");
        rollouts.start(rollout.id(), null);

        rollouts.advance(rollout.id(), Instant.now().plusSeconds(1));

        assertThat(tasksFor(rollout.id())).isEmpty();
        assertThat(rollouts.getInternal(rollout.id()).members().getFirst().status())
                .isEqualTo(AgentRolloutMember.Status.PENDING);
    }

    @Test
    void cancelTracksClaimedTaskLateReportAndRollsBackOnlyActualUpgrade() {
        List<Device> deviceList = devices(2, "cancel", "v1.20.13");
        AgentRolloutDtos.View rollout = createRollout(deviceList, 100, 1, 2, 0, 50);
        rollouts.start(rollout.id(), null);
        rollouts.advance(rollout.id(), Instant.now().plusSeconds(1));
        AgentRolloutDtos.View queued = rollouts.getInternal(rollout.id());
        AgentRolloutDtos.MemberView claimedMember = queued.members().getFirst();
        AgentRolloutDtos.MemberView unclaimedMember = queued.members().get(1);
        AgentTask claimed = tasks.findById(claimedMember.taskId()).orElseThrow();
        AgentTask unclaimed = tasks.findById(unclaimedMember.taskId()).orElseThrow();
        claimed.setStatus(AgentTask.Status.RUNNING);
        claimed.setStartedAt(Instant.now());
        tasks.saveAndFlush(claimed);

        AgentRolloutDtos.View canceled = rollouts.cancel(rollout.id(), "stop");

        assertThat(canceled.status()).isEqualTo(AgentRollout.Status.CANCELED);
        assertThat(tasks.findById(claimed.getId()).orElseThrow().getStatus()).isEqualTo(AgentTask.Status.RUNNING);
        assertThat(tasks.findById(unclaimed.getId()).orElseThrow().getStatus()).isEqualTo(AgentTask.Status.CANCELED);
        assertThat(member(canceled, claimedMember.id()).status()).isEqualTo(AgentRolloutMember.Status.QUEUED);
        assertThat(member(canceled, unclaimedMember.id()).status()).isEqualTo(AgentRolloutMember.Status.CANCELED);

        rollouts.advance(rollout.id(), claimedMember.queuedAt().plusSeconds(31));
        AgentRolloutDtos.View expired = rollouts.getInternal(rollout.id());
        assertThat(member(expired, claimedMember.id()).status()).isEqualTo(AgentRolloutMember.Status.QUEUED);
        assertThat(member(expired, claimedMember.id()).error()).contains("仍可能生效");

        claimed.setStatus(AgentTask.Status.SUCCEEDED);
        claimed.setFinishedAt(Instant.now());
        tasks.saveAndFlush(claimed);
        Device upgraded = devices.findById(claimedMember.deviceId()).orElseThrow();
        upgraded.setAgentVersion("v1.20.14");
        upgraded.setLastSeenAt(claimedMember.queuedAt().plusSeconds(32));
        devices.saveAndFlush(upgraded);
        AgentRolloutDtos.View rollingBack = rollouts.rollback(rollout.id(), "late update after cancel");
        assertThat(member(rollingBack, claimedMember.id()).status())
                .isEqualTo(AgentRolloutMember.Status.ROLLBACK_PENDING);
        assertThat(member(rollingBack, unclaimedMember.id()).status())
                .isEqualTo(AgentRolloutMember.Status.CANCELED);
    }

    @Test
    void operatorCanReadButCannotControlRollout() throws Exception {
        UserAccount operator = account("rollout-operator", UserAccount.Role.OPERATOR);
        Device visible = device("roles-visible", "v1.20.13");
        Device hidden = device("roles-hidden", "v1.20.13");
        access.replace(operator.getId(), new UserDtos.DevicePermissionRequest(List.of(
                new UserDtos.DevicePermissionItem(visible.getId(), true, false, false, false))));
        AgentRolloutDtos.View rollout = createRollout(List.of(visible, hidden), 100, 1, 1, 0, 50);
        var requestUser = user(operator.getUsername()).roles("OPERATOR");

        mvc.perform(get("/api/agent-rollouts/" + rollout.id()).with(requestUser))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.members.length()").value(1))
                .andExpect(jsonPath("$.members[0].deviceId").value(visible.getId()));
        mvc.perform(post("/api/agent-rollouts/" + rollout.id() + "/start").with(requestUser).with(csrf())
                        .contentType(MediaType.APPLICATION_JSON).content("{}"))
                .andExpect(status().isForbidden());
    }

    @Test
    void genericTaskEndpointCannotCancelRolloutUpdate() throws Exception {
        Device device = device("cancel-guard", "v1.20.13");
        AgentRolloutDtos.View rollout = createRollout(List.of(device), 100, 1, 1, 0, 50);
        rollouts.start(rollout.id(), null);
        rollouts.advance(rollout.id(), Instant.now().plusSeconds(1));
        AgentRolloutDtos.MemberView queued = rollouts.getInternal(rollout.id()).members().getFirst();

        UserAccount operator = account("cancel-guard-operator", UserAccount.Role.OPERATOR);
        access.replace(operator.getId(), new UserDtos.DevicePermissionRequest(List.of(
                new UserDtos.DevicePermissionItem(device.getId(), true, false, false, true))));

        mvc.perform(post("/api/tasks/" + queued.taskId() + "/cancel")
                        .with(user("admin").roles("ADMIN")).with(csrf()))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.message").value("Agent 更新任务必须通过 rollout 管理，不能单独取消"));
        mvc.perform(post("/api/tasks/" + queued.taskId() + "/cancel")
                        .with(user(operator.getUsername()).roles("OPERATOR")).with(csrf()))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.message").value("Agent 更新任务必须通过 rollout 管理，不能单独取消"));

        assertThat(tasks.findById(queued.taskId()).orElseThrow().getStatus()).isEqualTo(AgentTask.Status.QUEUED);
        assertThat(member(rollouts.getInternal(rollout.id()), queued.id()).status())
                .isEqualTo(AgentRolloutMember.Status.QUEUED);
    }

    @Test
    void rejectsDuplicateDevicesAndUnstableVersions() {
        Device device = device("validation", "v1.20.13");
        assertThatThrownBy(() -> rollouts.create(new AgentRolloutDtos.CreateRequest(
                "v1.20.14", List.of(device.getId(), device.getId()), null,
                10, 2, 1, 0, 20, 30), "test"))
                .isInstanceOf(ApiException.class).hasMessageContaining("不能重复");
        assertThatThrownBy(() -> rollouts.create(new AgentRolloutDtos.CreateRequest(
                "v1.20.14-rc.1", List.of(device.getId()), null,
                10, 2, 1, 0, 20, 30), "test"))
                .isInstanceOf(ApiException.class).hasMessageContaining("目标版本无效");
    }

    @Test
    void rejectsControllerManagedAgent() {
        Device device = device("controller-managed", "v1.20.13");
        device.setControllerManaged(true);
        devices.saveAndFlush(device);

        assertThatThrownBy(() -> createRollout(List.of(device), 100, 1, 1, 0, 50))
                .isInstanceOf(ApiException.class).hasMessageContaining("Controller 镜像更新");
    }

    private AgentRolloutDtos.View createRollout(List<Device> deviceList, int canaryPercent, int ringCount,
                                                int maxConcurrent, int jitterSeconds, int failureThreshold) {
        return rollouts.create(new AgentRolloutDtos.CreateRequest(
                "v1.20.14", deviceList.stream().map(Device::getId).toList(), null,
                canaryPercent, ringCount, maxConcurrent, jitterSeconds, failureThreshold, 30), "test");
    }

    private void assertRollbackTracksLateForwardUpdate(AgentTask.Status taskStatus,
                                                       AgentRolloutMember.Status expectedWaitingStatus) {
        Device device = device("late-forward-" + taskStatus.name().toLowerCase(Locale.ROOT), "v1.20.13");
        AgentRolloutDtos.View rollout = createRollout(List.of(device), 100, 1, 1, 0, 50);
        rollouts.start(rollout.id(), null);
        Instant tick = Instant.now().plusSeconds(1);
        rollouts.advance(rollout.id(), tick);
        AgentRolloutDtos.MemberView queued = rollouts.getInternal(rollout.id()).members().getFirst();
        AgentTask task = tasks.findById(queued.taskId()).orElseThrow();
        task.setStatus(taskStatus);
        task.setStartedAt(queued.queuedAt().plusMillis(1));
        if (taskStatus != AgentTask.Status.RUNNING) task.setFinishedAt(queued.queuedAt().plusMillis(2));
        tasks.saveAndFlush(task);

        AgentRolloutDtos.View rollingBack = rollouts.rollback(rollout.id(), "track late forward update");
        assertThat(rollingBack.status()).isEqualTo(AgentRollout.Status.ROLLING_BACK);
        assertThat(rollingBack.rollbackTotal()).isEqualTo(1);
        assertThat(rollingBack.currentRing()).isEqualTo(-1);
        assertThat(rollingBack.members().getFirst().status()).isEqualTo(expectedWaitingStatus);

        device.setAgentVersion("v1.20.14");
        device.setLastSeenAt(queued.queuedAt().plusSeconds(1));
        devices.saveAndFlush(device);
        rollouts.advance(rollout.id(), tick.plusSeconds(2));

        AgentRolloutDtos.MemberView rollbackQueued = rollouts.getInternal(rollout.id()).members().getFirst();
        assertThat(rollbackQueued.status()).isEqualTo(AgentRolloutMember.Status.ROLLBACK_QUEUED);
        assertThat(tasksFor(rollout.id())).hasSize(2);
        assertThat(payload(rollbackQueued.taskId()).path("action").asText()).isEqualTo("rollback");
    }

    private AgentRolloutDtos.View completeForwardRollout(Device device) {
        AgentRolloutDtos.View rollout = createRollout(List.of(device), 100, 1, 1, 0, 50);
        rollouts.start(rollout.id(), null);
        Instant tick = Instant.now().plusSeconds(1);
        rollouts.advance(rollout.id(), tick);
        AgentRolloutDtos.MemberView queued = rollouts.getInternal(rollout.id()).members().getFirst();
        device.setAgentVersion("v1.20.14");
        device.setLastSeenAt(queued.queuedAt().plusMillis(1));
        devices.saveAndFlush(device);
        rollouts.advance(rollout.id(), tick.plusSeconds(1));
        AgentRolloutDtos.View completed = rollouts.getInternal(rollout.id());
        assertThat(completed.status()).isEqualTo(AgentRollout.Status.SUCCEEDED);
        return completed;
    }

    private Device device(String prefix, String version) {
        Device device = new Device();
        device.setName(prefix + "-" + UUID.randomUUID());
        device.setAgentKeyHash("unused-test-hash");
        device.setAgentKeyPrefix("testkey");
        device.setAgentVersion(version);
        return devices.saveAndFlush(device);
    }

    private UserAccount account(String usernamePrefix, UserAccount.Role role) {
        String username = usernamePrefix + "-" + UUID.randomUUID();
        UserAccount account = new UserAccount();
        account.setUsername(username);
        account.setDisplayName(username);
        account.setPasswordHash("test-only-password-hash");
        account.setRole(role);
        account.setEnabled(true);
        return users.saveAndFlush(account);
    }

    private List<Device> devices(int count, String prefix, String version) {
        List<Device> result = new ArrayList<>();
        for (int index = 0; index < count; index++) result.add(device(prefix + "-" + index, version));
        return result;
    }

    private Map<String, String> assignments(AgentRolloutDtos.View rollout) {
        return rollout.members().stream().collect(Collectors.toMap(
                AgentRolloutDtos.MemberView::deviceId,
                member -> member.ring() + ":" + member.order()));
    }

    private AgentRolloutDtos.MemberView member(AgentRolloutDtos.View rollout, Long id) {
        return rollout.members().stream().filter(value -> value.id().equals(id)).findFirst().orElseThrow();
    }

    private AgentRolloutDtos.MemberView memberByDevice(AgentRolloutDtos.View rollout, String deviceId) {
        return rollout.members().stream().filter(value -> value.deviceId().equals(deviceId)).findFirst().orElseThrow();
    }

    private long inFlight(AgentRolloutDtos.View rollout) {
        return rollout.members().stream().filter(member -> Set.of(
                AgentRolloutMember.Status.QUEUED, AgentRolloutMember.Status.ACCEPTED,
                AgentRolloutMember.Status.ROLLBACK_QUEUED, AgentRolloutMember.Status.ROLLBACK_ACCEPTED)
                .contains(member.status())).count();
    }

    private List<AgentTask> tasksFor(Long rolloutId) {
        return tasks.findAll().stream().filter(task -> {
            try {
                return mapper.readTree(task.getPayloadJson()).path("rolloutId").asLong() == rolloutId;
            } catch (Exception ignored) {
                return false;
            }
        }).toList();
    }

    private JsonNode payload(Long taskId) {
        try {
            return mapper.readTree(tasks.findById(taskId).orElseThrow().getPayloadJson());
        } catch (Exception exception) {
            throw new AssertionError(exception);
        }
    }

    private <T> Iterable<T> iterable(Iterator<T> iterator) {
        return () -> iterator;
    }
}
