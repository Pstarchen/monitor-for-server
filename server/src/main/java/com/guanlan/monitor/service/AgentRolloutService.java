package com.guanlan.monitor.service;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.api.dto.AgentRolloutDtos;
import com.guanlan.monitor.api.dto.AgentTaskDtos;
import com.guanlan.monitor.domain.AgentRollout;
import com.guanlan.monitor.domain.AgentRolloutMember;
import com.guanlan.monitor.domain.AgentTask;
import com.guanlan.monitor.domain.Device;
import com.guanlan.monitor.domain.MaintenanceWindow;
import com.guanlan.monitor.repository.AgentRolloutMemberRepository;
import com.guanlan.monitor.repository.AgentRolloutRepository;
import com.guanlan.monitor.repository.AgentTaskRepository;
import com.guanlan.monitor.repository.DeviceRepository;
import com.guanlan.monitor.repository.MaintenanceWindowRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.PageRequest;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.Authentication;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.util.*;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

@Service
@RequiredArgsConstructor
public class AgentRolloutService {
    private static final Pattern STABLE_VERSION = Pattern.compile(
            "^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$");
    private static final Set<AgentRolloutMember.Status> UPDATE_IN_FLIGHT = Set.of(
            AgentRolloutMember.Status.QUEUED, AgentRolloutMember.Status.ACCEPTED);
    private static final Set<AgentRolloutMember.Status> ROLLBACK_IN_FLIGHT = Set.of(
            AgentRolloutMember.Status.ROLLBACK_QUEUED, AgentRolloutMember.Status.ROLLBACK_ACCEPTED);
    private static final Set<AgentRollout.Status> DEVICE_RESERVING_ROLLOUTS = Set.of(
            AgentRollout.Status.RUNNING, AgentRollout.Status.PAUSED, AgentRollout.Status.ROLLING_BACK);
    private static final int DEFAULT_CANARY_PERCENT = 10;
    private static final int DEFAULT_RING_COUNT = 3;
    private static final int DEFAULT_MAX_CONCURRENT = 5;
    private static final int DEFAULT_JITTER_SECONDS = 30;
    private static final int DEFAULT_FAILURE_THRESHOLD = 20;
    private static final int DEFAULT_VERIFICATION_TIMEOUT_SECONDS = 600;

    private final AgentRolloutRepository rollouts;
    private final AgentRolloutMemberRepository members;
    private final DeviceRepository devices;
    private final MaintenanceWindowRepository maintenanceWindows;
    private final MaintenanceWindowService maintenanceWindowService;
    private final AgentTaskService tasks;
    private final AgentTaskRepository taskRepository;
    private final AuditService audit;
    private final DeviceAccessService access;

    @Transactional
    public AgentRolloutDtos.View create(AgentRolloutDtos.CreateRequest request, String actor) {
        if (request == null) throw new ApiException(HttpStatus.BAD_REQUEST, "Agent rollout 请求不能为空");
        String targetVersion = requireStableVersion(request.targetVersion(), "目标版本无效");
        List<String> deviceIds = validateDeviceIds(request.deviceIds());
        int canaryPercent = value(request.canaryPercent(), DEFAULT_CANARY_PERCENT);
        int ringCount = value(request.ringCount(), DEFAULT_RING_COUNT);
        int maxConcurrent = value(request.maxConcurrent(), DEFAULT_MAX_CONCURRENT);
        int jitterSeconds = value(request.jitterSeconds(), DEFAULT_JITTER_SECONDS);
        int failureThreshold = value(request.failureThreshold(), DEFAULT_FAILURE_THRESHOLD);
        int verificationTimeout = value(request.verificationTimeoutSeconds(), DEFAULT_VERIFICATION_TIMEOUT_SECONDS);
        validateSettings(canaryPercent, ringCount, maxConcurrent, jitterSeconds, failureThreshold, verificationTimeout);

        MaintenanceWindow maintenanceWindow = null;
        if (request.maintenanceWindowId() != null) {
            maintenanceWindow = maintenanceWindows.findById(request.maintenanceWindowId())
                    .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "维护窗口不存在"));
        }

        Map<String, Device> byId = new HashMap<>();
        devices.findAllById(deviceIds).forEach(device -> byId.put(device.getId(), device));
        if (byId.size() != deviceIds.size()) {
            throw new ApiException(HttpStatus.NOT_FOUND, "一个或多个 rollout 设备不存在");
        }
        for (String deviceId : deviceIds) {
            Device device = byId.get(deviceId);
            if (device.isControllerManaged()) {
                throw new ApiException(HttpStatus.BAD_REQUEST,
                        "总控内置 Agent 必须随 Controller 镜像更新，不能加入 Agent rollout");
            }
            String previous = requireStableVersion(device.getAgentVersion(),
                    "设备 " + deviceId + " 尚未上报稳定 Agent 版本");
            if (compareVersions(targetVersion, previous) <= 0) {
                throw new ApiException(HttpStatus.BAD_REQUEST, "目标版本必须高于设备 " + deviceId + " 的当前版本");
            }
        }

        AgentRollout rollout = new AgentRollout();
        rollout.setTargetVersion(targetVersion);
        rollout.setMaintenanceWindow(maintenanceWindow);
        rollout.setCanaryPercent(canaryPercent);
        rollout.setRingCount(ringCount);
        rollout.setMaxConcurrent(maxConcurrent);
        rollout.setJitterSeconds(jitterSeconds);
        rollout.setFailureThreshold(failureThreshold);
        rollout.setVerificationTimeoutSeconds(verificationTimeout);
        rollout.setCreatedBy(normalizeActor(actor));
        rollouts.save(rollout);

        List<Device> ordered = deviceIds.stream().map(byId::get)
                .sorted(Comparator.comparing((Device device) -> stableHash(device.getId()))
                        .thenComparing(Device::getId))
                .toList();
        int canaryCount = canaryCount(ordered.size(), canaryPercent, ringCount);
        List<AgentRolloutMember> createdMembers = new ArrayList<>(ordered.size());
        for (int index = 0; index < ordered.size(); index++) {
            Device device = ordered.get(index);
            AgentRolloutMember member = new AgentRolloutMember();
            member.setRollout(rollout);
            member.setDevice(device);
            member.setPreviousVersion(device.getAgentVersion());
            member.setRingNumber(ringFor(index, ordered.size(), canaryCount, ringCount));
            member.setOrderIndex(index);
            createdMembers.add(member);
        }
        members.saveAll(createdMembers);
        audit.record("AGENT_ROLLOUT_CREATE", "rollout:" + rollout.getId(),
                "创建 Agent rollout，目标版本 " + targetVersion + "，设备数 " + ordered.size());
        return view(rollout, createdMembers);
    }

    @Transactional(readOnly = true)
    public List<AgentRolloutDtos.View> list(int limit, Authentication authentication) {
        Set<String> visible = access.visibleDeviceIds(authentication);
        return rollouts.findAllByOrderByCreatedAtDesc(PageRequest.of(0, Math.min(Math.max(limit, 1), 100)))
                .stream().map(rollout -> visibleView(rollout, visible))
                .filter(view -> !view.members().isEmpty())
                .toList();
    }

    @Transactional(readOnly = true)
    public AgentRolloutDtos.View get(Long id, Authentication authentication) {
        AgentRollout rollout = require(id);
        AgentRolloutDtos.View view = visibleView(rollout, access.visibleDeviceIds(authentication));
        if (view.members().isEmpty()) throw new ApiException(HttpStatus.FORBIDDEN, "无权查看该 Agent rollout");
        return view;
    }

    @Transactional(readOnly = true)
    AgentRolloutDtos.View getInternal(Long id) {
        AgentRollout rollout = require(id);
        return view(rollout, members.findByRolloutIdOrderByOrderIndex(id));
    }

    @Transactional
    public AgentRolloutDtos.View start(Long id, String reason) {
        AgentRollout rollout = lock(id);
        if (rollout.getStatus() != AgentRollout.Status.DRAFT) {
            throw conflict("只有草稿 rollout 可以启动");
        }
        List<Device> lockedDevices = lockRolloutDevices(id);
        ensureDevicesAvailable(id, lockedDevices);
        List<AgentRolloutMember> rolloutMembers = members.findByRolloutIdOrderByOrderIndex(id);
        Map<String, Device> devicesById = new HashMap<>();
        lockedDevices.forEach(device -> devicesById.put(device.getId(), device));
        for (AgentRolloutMember member : rolloutMembers) {
            Device device = devicesById.get(member.getDevice().getId());
            if (device == null) throw conflict("rollout 设备不存在");
            if (device.isControllerManaged()) {
                throw conflict("总控内置 Agent 不能启动独立 Agent rollout");
            }
            if (!Objects.equals(member.getPreviousVersion(), device.getAgentVersion())) {
                throw conflict("设备 " + device.getId() + " 的 Agent 版本已从 "
                        + member.getPreviousVersion() + " 变为 " + displayVersion(device.getAgentVersion())
                        + "，请重新创建 rollout");
            }
        }
        Instant now = Instant.now();
        int firstRing = nextRing(rolloutMembers, -1, false);
        if (firstRing < 0) throw conflict("rollout 没有可更新成员");
        rollout.setStatus(AgentRollout.Status.RUNNING);
        rollout.setCurrentRing(firstRing);
        rollout.setStartedAt(now);
        rollout.setCompletedAt(null);
        rollout.setStatusReason(cleanReason(reason, "已启动"));
        rollout.setUpdatedAt(now);
        activateRing(rollout, rolloutMembers, firstRing, now, false);
        audit.record("AGENT_ROLLOUT_START", "rollout:" + id, "启动 Agent rollout");
        return view(rollout, rolloutMembers);
    }

    @Transactional
    public AgentRolloutDtos.View pause(Long id, String reason) {
        AgentRollout rollout = lock(id);
        if (rollout.getStatus() != AgentRollout.Status.RUNNING
                && rollout.getStatus() != AgentRollout.Status.ROLLING_BACK) {
            throw conflict("当前 rollout 不能暂停");
        }
        Instant now = Instant.now();
        rollout.setStatus(AgentRollout.Status.PAUSED);
        rollout.setStatusReason(cleanReason(reason, "已由管理员暂停"));
        rollout.setUpdatedAt(now);
        audit.record("AGENT_ROLLOUT_PAUSE", "rollout:" + id, rollout.getStatusReason());
        return view(rollout, members.findByRolloutIdOrderByOrderIndex(id));
    }

    @Transactional
    public AgentRolloutDtos.View resume(Long id, String reason) {
        AgentRollout rollout = lock(id);
        if (rollout.getStatus() != AgentRollout.Status.PAUSED) {
            throw conflict("只有暂停的 rollout 可以恢复");
        }
        List<Device> lockedDevices = lockRolloutDevices(id);
        ensureDevicesAvailable(id, lockedDevices);
        rollout.setStatus(rollout.getRollbackStartedAt() == null
                ? AgentRollout.Status.RUNNING : AgentRollout.Status.ROLLING_BACK);
        rollout.setStatusReason(cleanReason(reason, "已由管理员恢复"));
        rollout.setUpdatedAt(Instant.now());
        audit.record("AGENT_ROLLOUT_RESUME", "rollout:" + id, rollout.getStatusReason());
        return view(rollout, members.findByRolloutIdOrderByOrderIndex(id));
    }

    @Transactional
    public AgentRolloutDtos.View cancel(Long id, String reason) {
        AgentRollout rollout = lock(id);
        if (!Set.of(AgentRollout.Status.DRAFT, AgentRollout.Status.RUNNING,
                AgentRollout.Status.PAUSED, AgentRollout.Status.ROLLING_BACK).contains(rollout.getStatus())) {
            throw conflict("当前 rollout 不能取消");
        }
        List<AgentRolloutMember> rolloutMembers = members.findByRolloutIdOrderByOrderIndex(id);
        Instant now = Instant.now();
        for (AgentRolloutMember member : rolloutMembers) {
            if (member.getStatus() == AgentRolloutMember.Status.PENDING) {
                member.setStatus(AgentRolloutMember.Status.CANCELED);
                member.setError("rollout 已取消");
            } else if (UPDATE_IN_FLIGHT.contains(member.getStatus())) {
                boolean canceled = cancelUnclaimedTask(member.getTask(), now, "rollout 已取消");
                if (canceled || !mayStillApply(member.getTask())) {
                    member.setStatus(AgentRolloutMember.Status.CANCELED);
                    member.setError("rollout 已取消");
                } else {
                    member.setError("rollout 已取消，等待已领取任务的版本上报");
                }
            } else if (member.getStatus() == AgentRolloutMember.Status.ROLLBACK_PENDING) {
                member.setStatus(AgentRolloutMember.Status.CANCELED);
                member.setError("rollout 回滚已取消");
            } else if (ROLLBACK_IN_FLIGHT.contains(member.getStatus())) {
                boolean canceled = cancelUnclaimedTask(member.getTask(), now, "rollout 回滚已取消");
                if (canceled || !mayStillApply(member.getTask())) {
                    member.setStatus(AgentRolloutMember.Status.CANCELED);
                    member.setError("rollout 回滚已取消");
                } else {
                    member.setError("rollout 回滚已取消，等待已领取任务的版本上报");
                }
            }
        }
        rollout.setStatus(AgentRollout.Status.CANCELED);
        rollout.setStatusReason(cleanReason(reason, "已由管理员取消"));
        rollout.setCompletedAt(now);
        rollout.setUpdatedAt(now);
        audit.record("AGENT_ROLLOUT_CANCEL", "rollout:" + id, rollout.getStatusReason());
        return view(rollout, rolloutMembers);
    }

    @Transactional
    public AgentRolloutDtos.View rollback(Long id, String reason) {
        AgentRollout rollout = lock(id);
        if (rollout.getRollbackStartedAt() != null
                || !Set.of(AgentRollout.Status.RUNNING, AgentRollout.Status.PAUSED,
                AgentRollout.Status.CANCELED, AgentRollout.Status.SUCCEEDED,
                AgentRollout.Status.FAILED).contains(rollout.getStatus())) {
            throw conflict("当前 rollout 不能回滚");
        }
        List<Device> lockedDevices = lockRolloutDevices(id);
        ensureDevicesAvailable(id, lockedDevices);
        List<AgentRolloutMember> rolloutMembers = members.findByRolloutIdOrderByOrderIndex(id);
        Instant now = Instant.now();
        int rollbackTotal = 0;
        for (AgentRolloutMember member : rolloutMembers) {
            String currentVersion = member.getDevice().getAgentVersion();
            boolean currentlyOnTarget = rollout.getTargetVersion().equals(currentVersion);
            if (currentlyOnTarget && (member.getStatus() == AgentRolloutMember.Status.CONFIRMED
                    || isConfirmedByReport(member, rollout.getTargetVersion()))) {
                makeRollbackPending(member);
                rollbackTotal++;
                continue;
            }
            if (member.getStatus() == AgentRolloutMember.Status.CONFIRMED) {
                skipRollbackForVersionDrift(member, rollout.getTargetVersion(), currentVersion);
                continue;
            }

            boolean canceled = cancelUnclaimedTask(member.getTask(), now, "rollout 已进入回滚");
            if (canceled) {
                cancelRollbackParticipant(member, "前向更新任务已在领取前取消");
            } else if (mayStillApply(member.getTask())) {
                awaitForwardUpdateBeforeRollback(member);
                rollbackTotal++;
            } else if (member.getStatus() != AgentRolloutMember.Status.FAILED) {
                cancelRollbackParticipant(member, "未确认升级，不进入回滚");
            }
        }
        if (rollbackTotal == 0) throw conflict("没有当前仍处于目标版本或可能完成升级的成员可回滚");

        int firstRing = nextRing(rolloutMembers, Integer.MAX_VALUE, true);
        rollout.setStatus(AgentRollout.Status.ROLLING_BACK);
        rollout.setCurrentRing(firstRing);
        rollout.setRollbackStartedAt(now);
        rollout.setCompletedAt(null);
        rollout.setStatusReason(cleanReason(reason, "已开始回滚"));
        rollout.setUpdatedAt(now);
        if (firstRing >= 0) activateRing(rollout, rolloutMembers, firstRing, now, true);
        audit.record("AGENT_ROLLOUT_ROLLBACK", "rollout:" + id, rollout.getStatusReason());
        return view(rollout, rolloutMembers);
    }

    @Transactional
    public void advance(Long id, Instant now) {
        AgentRollout rollout = rollouts.lockById(id).orElse(null);
        if (rollout == null) return;

        if (rollout.getStatus() == AgentRollout.Status.ROLLING_BACK) lockRolloutDevices(id);
        List<AgentRolloutMember> rolloutMembers = members.findByRolloutIdOrderByOrderIndex(id);
        if (rollout.getStatus() == AgentRollout.Status.CANCELED) {
            reconcileCanceled(rollout, rolloutMembers, now);
            return;
        }
        if (rollout.getStatus() != AgentRollout.Status.RUNNING
                && rollout.getStatus() != AgentRollout.Status.ROLLING_BACK) return;

        boolean rollback = rollout.getStatus() == AgentRollout.Status.ROLLING_BACK;
        boolean newFailure = false;
        if (rollback) {
            newFailure = reconcileForwardUpdatesDuringRollback(rollout, rolloutMembers, now);
            if (rollout.getCurrentRing() < 0) {
                int firstRing = nextRing(rolloutMembers, Integer.MAX_VALUE, true);
                if (firstRing < 0) {
                    if (hasForwardAwaitingRollback(rolloutMembers)) return;
                    complete(rollout, rolloutMembers, now, true);
                    return;
                }
                rollout.setCurrentRing(firstRing);
                rollout.setUpdatedAt(now);
                activateRing(rollout, rolloutMembers, firstRing, now, true);
            }
        }
        newFailure |= reconcile(rollout, rolloutMembers, now, rollback);
        if (newFailure && failureThresholdReached(rollout, rolloutMembers, rollback)) {
            rollout.setStatus(AgentRollout.Status.PAUSED);
            rollout.setStatusReason("当前 ring 的失败率达到 " + rollout.getFailureThreshold() + "%，已自动暂停");
            rollout.setUpdatedAt(now);
            audit.record("AGENT_ROLLOUT_AUTO_PAUSE", "rollout:" + id, rollout.getStatusReason());
            return;
        }

        if (ringComplete(rolloutMembers, rollout.getCurrentRing(), rollback)) {
            int next = nextRing(rolloutMembers, rollout.getCurrentRing(), rollback);
            if (next < 0) {
                if (rollback && hasForwardAwaitingRollback(rolloutMembers)) return;
                complete(rollout, rolloutMembers, now, rollback);
                return;
            }
            rollout.setCurrentRing(next);
            rollout.setUpdatedAt(now);
            activateRing(rollout, rolloutMembers, next, now, rollback);
        }

        if (rollout.getMaintenanceWindow() != null
                && !maintenanceWindowService.isActive(rollout.getMaintenanceWindow(), now)) return;

        Set<AgentRolloutMember.Status> activeStatuses = rollback ? ROLLBACK_IN_FLIGHT : UPDATE_IN_FLIGHT;
        long active = rolloutMembers.stream().filter(member -> activeStatuses.contains(member.getStatus())).count();
        AgentRolloutMember.Status pending = rollback
                ? AgentRolloutMember.Status.ROLLBACK_PENDING : AgentRolloutMember.Status.PENDING;
        for (AgentRolloutMember member : rolloutMembers) {
            if (active >= rollout.getMaxConcurrent()) break;
            if (member.getRingNumber() != rollout.getCurrentRing() || member.getStatus() != pending
                    || member.getEligibleAt() == null || member.getEligibleAt().isAfter(now)) continue;
            if (rollback && !readyToDispatchRollback(rollout, member)) continue;
            String action = rollback ? "rollback" : "update";
            String version = rollback ? member.getPreviousVersion() : rollout.getTargetVersion();
            tasks.createUpdateAt(new AgentTaskDtos.UpdateRequest(
                    member.getDevice().getId(), action, version, rollout.getId(), member.getId()), "system", now);
            active++;
        }
    }

    private boolean reconcile(AgentRollout rollout, List<AgentRolloutMember> rolloutMembers,
                              Instant now, boolean rollback) {
        Set<AgentRolloutMember.Status> inFlight = rollback ? ROLLBACK_IN_FLIGHT : UPDATE_IN_FLIGHT;
        boolean newFailure = false;
        for (AgentRolloutMember member : rolloutMembers) {
            if (member.getRingNumber() != rollout.getCurrentRing() || !inFlight.contains(member.getStatus())) continue;
            String expectedVersion = rollback ? member.getPreviousVersion() : rollout.getTargetVersion();
            if (isConfirmedByReport(member, expectedVersion)) {
                member.setStatus(rollback ? AgentRolloutMember.Status.ROLLBACK_CONFIRMED
                        : AgentRolloutMember.Status.CONFIRMED);
                member.setConfirmedAt(member.getDevice().getLastSeenAt());
                member.setError(null);
                continue;
            }

            AgentTask task = member.getTask();
            if (task != null && task.getStatus() == AgentTask.Status.SUCCEEDED) {
                member.setStatus(rollback ? AgentRolloutMember.Status.ROLLBACK_ACCEPTED
                        : AgentRolloutMember.Status.ACCEPTED);
            } else if (task != null && Set.of(AgentTask.Status.FAILED, AgentTask.Status.TIMED_OUT,
                    AgentTask.Status.CANCELED).contains(task.getStatus())) {
                fail(member, rollback, task.getError() == null || task.getError().isBlank()
                        ? "Agent 未接受更新任务" : task.getError());
                newFailure = true;
                continue;
            }

            if (member.getQueuedAt() != null
                    && !member.getQueuedAt().plusSeconds(rollout.getVerificationTimeoutSeconds()).isAfter(now)) {
                cancelUnclaimedTask(task, now, "等待 Agent 版本上报超时");
                fail(member, rollback, "等待 Agent 版本上报超时");
                newFailure = true;
            }
        }
        return newFailure;
    }

    private boolean reconcileForwardUpdatesDuringRollback(AgentRollout rollout,
                                                            List<AgentRolloutMember> rolloutMembers,
                                                            Instant now) {
        boolean newFailure = false;
        for (AgentRolloutMember member : rolloutMembers) {
            if (!member.isRollbackParticipant() || !UPDATE_IN_FLIGHT.contains(member.getStatus())) continue;
            if (isConfirmedByReport(member, rollout.getTargetVersion())) {
                makeRollbackPending(member);
                continue;
            }
            if (hasReportedVersionDrift(member, rollout.getTargetVersion())) {
                fail(member, true, versionDriftMessage(member, rollout.getTargetVersion()));
                newFailure = true;
                continue;
            }

            AgentTask task = member.getTask();
            if (cancelUnclaimedTask(task, now, "回滚前取消尚未领取的前向更新任务")
                    || (task != null && task.getStatus() == AgentTask.Status.CANCELED)) {
                cancelRollbackParticipant(member, "前向更新任务已在领取前取消");
                continue;
            }
            if (!mayStillApply(task)) {
                String error = task != null && task.getError() != null && !task.getError().isBlank()
                        ? task.getError() : "前向更新任务已结束，但无法确认设备版本";
                fail(member, true, error);
                newFailure = true;
                continue;
            }
            member.setStatus(task.getStatus() == AgentTask.Status.RUNNING
                    || task.getStatus() == AgentTask.Status.QUEUED
                    ? AgentRolloutMember.Status.QUEUED : AgentRolloutMember.Status.ACCEPTED);

            Instant waitingSince = rollout.getRollbackStartedAt();
            if (waitingSince != null
                    && !waitingSince.plusSeconds(rollout.getVerificationTimeoutSeconds()).isAfter(now)) {
                fail(member, true, "回滚期间等待前向更新版本上报超时");
                newFailure = true;
            }
        }
        return newFailure;
    }

    private boolean hasForwardAwaitingRollback(List<AgentRolloutMember> rolloutMembers) {
        return rolloutMembers.stream().anyMatch(member -> member.isRollbackParticipant()
                && UPDATE_IN_FLIGHT.contains(member.getStatus()));
    }

    private void makeRollbackPending(AgentRolloutMember member) {
        member.setStatus(AgentRolloutMember.Status.ROLLBACK_PENDING);
        member.setTask(null);
        member.setEligibleAt(null);
        member.setQueuedAt(null);
        member.setConfirmedAt(null);
        member.setError(null);
        member.setRollbackParticipant(true);
    }

    private void awaitForwardUpdateBeforeRollback(AgentRolloutMember member) {
        AgentTask task = member.getTask();
        member.setStatus(task != null && (task.getStatus() == AgentTask.Status.SUCCEEDED
                || task.getStatus() == AgentTask.Status.TIMED_OUT)
                ? AgentRolloutMember.Status.ACCEPTED : AgentRolloutMember.Status.QUEUED);
        member.setRollbackParticipant(true);
        member.setConfirmedAt(null);
        member.setError("等待已领取的前向更新任务完成版本上报");
    }

    private void cancelRollbackParticipant(AgentRolloutMember member, String reason) {
        member.setStatus(AgentRolloutMember.Status.CANCELED);
        member.setRollbackParticipant(false);
        member.setError(reason);
    }

    private void skipRollbackForVersionDrift(AgentRolloutMember member, String targetVersion,
                                             String currentVersion) {
        member.setStatus(AgentRolloutMember.Status.CANCELED);
        member.setRollbackParticipant(false);
        member.setError("设备 Agent 版本已从 rollout 目标 " + targetVersion + " 变为 "
                + displayVersion(currentVersion) + "，跳过旧 rollout 回滚");
    }

    private boolean hasReportedVersionDrift(AgentRolloutMember member, String targetVersion) {
        Instant queuedAt = member.getQueuedAt();
        Instant lastSeenAt = member.getDevice().getLastSeenAt();
        String currentVersion = member.getDevice().getAgentVersion();
        return queuedAt != null && lastSeenAt != null && !lastSeenAt.isBefore(queuedAt)
                && currentVersion != null && !targetVersion.equals(currentVersion)
                && !member.getPreviousVersion().equals(currentVersion);
    }

    private String versionDriftMessage(AgentRolloutMember member, String targetVersion) {
        return "设备 Agent 版本已从 rollout 目标 " + targetVersion + " 变为 "
                + displayVersion(member.getDevice().getAgentVersion()) + "，拒绝降级回滚";
    }

    private boolean readyToDispatchRollback(AgentRollout rollout, AgentRolloutMember member) {
        String currentVersion = member.getDevice().getAgentVersion();
        if (rollout.getTargetVersion().equals(currentVersion)) return true;
        if (member.getPreviousVersion().equals(currentVersion)) {
            member.setStatus(AgentRolloutMember.Status.ROLLBACK_CONFIRMED);
            member.setConfirmedAt(member.getDevice().getLastSeenAt());
            member.setError(null);
            return false;
        }
        fail(member, true, versionDriftMessage(member, rollout.getTargetVersion()));
        return false;
    }

    private boolean isConfirmedByReport(AgentRolloutMember member, String expectedVersion) {
        Instant queuedAt = member.getQueuedAt();
        Instant lastSeenAt = member.getDevice().getLastSeenAt();
        return queuedAt != null && lastSeenAt != null && !lastSeenAt.isBefore(queuedAt)
                && expectedVersion.equals(member.getDevice().getAgentVersion());
    }

    private void reconcileCanceled(AgentRollout rollout, List<AgentRolloutMember> rolloutMembers, Instant now) {
        for (AgentRolloutMember member : rolloutMembers) {
            boolean rollbackTask = ROLLBACK_IN_FLIGHT.contains(member.getStatus());
            if (!rollbackTask && !UPDATE_IN_FLIGHT.contains(member.getStatus())) continue;
            String expectedVersion = rollbackTask ? member.getPreviousVersion() : rollout.getTargetVersion();
            if (isConfirmedByReport(member, expectedVersion)) {
                member.setStatus(rollbackTask ? AgentRolloutMember.Status.ROLLBACK_CONFIRMED
                        : AgentRolloutMember.Status.CONFIRMED);
                member.setConfirmedAt(member.getDevice().getLastSeenAt());
                member.setError(null);
                continue;
            }
            AgentTask task = member.getTask();
            if (task != null && task.getStatus() == AgentTask.Status.SUCCEEDED) {
                member.setStatus(rollbackTask ? AgentRolloutMember.Status.ROLLBACK_ACCEPTED
                        : AgentRolloutMember.Status.ACCEPTED);
            } else if (!mayStillApply(task)) {
                member.setStatus(AgentRolloutMember.Status.CANCELED);
                member.setError("取消后任务未完成升级");
                continue;
            }
            if (member.getQueuedAt() != null
                    && !member.getQueuedAt().plusSeconds(rollout.getVerificationTimeoutSeconds()).isAfter(now)) {
                if (cancelUnclaimedTask(task, now, "取消后等待 Agent 版本上报超时")) {
                    member.setStatus(AgentRolloutMember.Status.CANCELED);
                    member.setError("取消后任务已在领取前取消");
                } else {
                    member.setError("取消后等待 Agent 版本上报超时，已领取任务仍可能生效");
                }
            }
        }
    }

    private void fail(AgentRolloutMember member, boolean rollback, String error) {
        member.setStatus(rollback ? AgentRolloutMember.Status.ROLLBACK_FAILED : AgentRolloutMember.Status.FAILED);
        member.setError(trim(error, 500));
    }

    private boolean failureThresholdReached(AgentRollout rollout,
                                            List<AgentRolloutMember> rolloutMembers, boolean rollback) {
        long failed = rolloutMembers.stream()
                .filter(member -> member.getRingNumber() == rollout.getCurrentRing())
                .filter(member -> member.getStatus() == (rollback
                        ? AgentRolloutMember.Status.ROLLBACK_FAILED : AgentRolloutMember.Status.FAILED))
                .count();
        long confirmed = rolloutMembers.stream()
                .filter(member -> member.getRingNumber() == rollout.getCurrentRing())
                .filter(member -> member.getStatus() == (rollback
                        ? AgentRolloutMember.Status.ROLLBACK_CONFIRMED : AgentRolloutMember.Status.CONFIRMED))
                .count();
        return failed > 0 && failed * 100 >= (failed + confirmed) * rollout.getFailureThreshold();
    }

    private boolean ringComplete(List<AgentRolloutMember> rolloutMembers, int ring, boolean rollback) {
        Set<AgentRolloutMember.Status> unfinished = rollback
                ? Set.of(AgentRolloutMember.Status.ROLLBACK_PENDING, AgentRolloutMember.Status.ROLLBACK_QUEUED,
                AgentRolloutMember.Status.ROLLBACK_ACCEPTED)
                : Set.of(AgentRolloutMember.Status.PENDING, AgentRolloutMember.Status.QUEUED,
                AgentRolloutMember.Status.ACCEPTED);
        return rolloutMembers.stream().filter(member -> member.getRingNumber() == ring)
                .noneMatch(member -> unfinished.contains(member.getStatus()));
    }

    private int nextRing(List<AgentRolloutMember> rolloutMembers, int currentRing, boolean rollback) {
        AgentRolloutMember.Status pending = rollback
                ? AgentRolloutMember.Status.ROLLBACK_PENDING : AgentRolloutMember.Status.PENDING;
        if (rollback) {
            return rolloutMembers.stream().filter(member -> member.getStatus() == pending)
                    .mapToInt(AgentRolloutMember::getRingNumber).max().orElse(-1);
        }
        return rolloutMembers.stream().filter(member -> member.getStatus() == pending)
                .mapToInt(AgentRolloutMember::getRingNumber)
                .filter(ring -> ring > currentRing).min().orElse(-1);
    }

    private void activateRing(AgentRollout rollout, List<AgentRolloutMember> rolloutMembers,
                              int ring, Instant now, boolean rollback) {
        AgentRolloutMember.Status pending = rollback
                ? AgentRolloutMember.Status.ROLLBACK_PENDING : AgentRolloutMember.Status.PENDING;
        for (AgentRolloutMember member : rolloutMembers) {
            if (member.getRingNumber() == ring && member.getStatus() == pending && member.getEligibleAt() == null) {
                member.setEligibleAt(now.plusSeconds(jitter(rollout.getId(), member.getDevice().getId(),
                        rollout.getJitterSeconds())));
            }
        }
    }

    private void complete(AgentRollout rollout, List<AgentRolloutMember> rolloutMembers,
                          Instant now, boolean rollback) {
        if (rollback && hasForwardAwaitingRollback(rolloutMembers)) return;
        AgentRolloutMember.Status failure = rollback
                ? AgentRolloutMember.Status.ROLLBACK_FAILED : AgentRolloutMember.Status.FAILED;
        long failures = rolloutMembers.stream().filter(member -> member.getStatus() == failure).count();
        if (failures == 0) {
            rollout.setStatus(rollback ? AgentRollout.Status.ROLLED_BACK : AgentRollout.Status.SUCCEEDED);
            rollout.setStatusReason(rollback ? "所有回滚成员均已通过版本上报确认" : "所有成员均已通过版本上报确认");
        } else {
            rollout.setStatus(AgentRollout.Status.FAILED);
            rollout.setStatusReason((rollback ? "回滚" : "更新") + "完成，但有 " + failures + " 个成员失败");
        }
        rollout.setCompletedAt(now);
        rollout.setUpdatedAt(now);
        audit.record("AGENT_ROLLOUT_COMPLETE", "rollout:" + rollout.getId(), rollout.getStatusReason());
    }

    private boolean cancelUnclaimedTask(AgentTask task, Instant now, String reason) {
        if (task == null || task.getStatus() != AgentTask.Status.QUEUED) return false;
        String error = trim(reason, 500);
        int canceled = taskRepository.cancelIfQueued(task.getId(), AgentTask.Status.QUEUED,
                AgentTask.Status.CANCELED, now, error);
        if (canceled == 1) {
            task.setStatus(AgentTask.Status.CANCELED);
            task.setFinishedAt(now);
            task.setError(error);
        }
        return canceled == 1;
    }

    private boolean mayStillApply(AgentTask task) {
        return task != null && (Set.of(AgentTask.Status.QUEUED, AgentTask.Status.RUNNING,
                AgentTask.Status.SUCCEEDED).contains(task.getStatus())
                || (task.getStatus() == AgentTask.Status.TIMED_OUT && task.getStartedAt() != null));
    }

    private boolean isInFlight(AgentRolloutMember.Status status) {
        return UPDATE_IN_FLIGHT.contains(status) || ROLLBACK_IN_FLIGHT.contains(status);
    }

    private int canaryCount(int size, int canaryPercent, int ringCount) {
        if (ringCount == 1) return size;
        if (canaryPercent == 0) return 0;
        return Math.min(size, Math.max(1, (size * canaryPercent + 99) / 100));
    }

    private int ringFor(int index, int size, int canaryCount, int ringCount) {
        if (ringCount == 1 || index < canaryCount) return 0;
        int remaining = size - canaryCount;
        if (remaining <= 0) return 0;
        int ring = 1 + ((index - canaryCount) * (ringCount - 1) / remaining);
        return Math.min(ring, ringCount - 1);
    }

    static String stableHash(String value) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
    }

    static long jitter(long rolloutId, String deviceId, int maximumSeconds) {
        if (maximumSeconds <= 0) return 0;
        String hash = stableHash(rolloutId + ":" + deviceId);
        long value = Long.parseUnsignedLong(hash.substring(0, 15), 16);
        return value % (maximumSeconds + 1L);
    }

    static int compareVersions(String left, String right) {
        Matcher leftMatcher = STABLE_VERSION.matcher(left == null ? "" : left);
        Matcher rightMatcher = STABLE_VERSION.matcher(right == null ? "" : right);
        if (!leftMatcher.matches() || !rightMatcher.matches()) {
            throw new IllegalArgumentException("versions must use vX.Y.Z");
        }
        for (int group = 1; group <= 3; group++) {
            int compared = new BigInteger(leftMatcher.group(group)).compareTo(new BigInteger(rightMatcher.group(group)));
            if (compared != 0) return compared;
        }
        return 0;
    }

    private List<String> validateDeviceIds(List<String> values) {
        if (values == null || values.isEmpty() || values.size() > 500) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "rollout 必须显式指定 1 到 500 个设备");
        }
        LinkedHashSet<String> unique = new LinkedHashSet<>();
        for (String value : values) {
            if (value == null || value.isBlank() || value.length() > 36 || !value.equals(value.trim())) {
                throw new ApiException(HttpStatus.BAD_REQUEST, "rollout 设备 ID 无效");
            }
            if (!unique.add(value)) throw new ApiException(HttpStatus.BAD_REQUEST, "rollout 设备 ID 不能重复");
        }
        return List.copyOf(unique);
    }

    private void validateSettings(int canaryPercent, int ringCount, int maxConcurrent, int jitterSeconds,
                                  int failureThreshold, int verificationTimeout) {
        if (canaryPercent < 0 || canaryPercent > 100 || ringCount < 1 || ringCount > 20
                || maxConcurrent < 1 || maxConcurrent > 100 || jitterSeconds < 0 || jitterSeconds > 86_400
                || failureThreshold < 1 || failureThreshold > 100
                || verificationTimeout < 30 || verificationTimeout > 86_400) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "Agent rollout 参数超出允许范围");
        }
    }

    private String requireStableVersion(String version, String message) {
        if (version == null || version.length() > 32 || !STABLE_VERSION.matcher(version).matches()) {
            throw new ApiException(HttpStatus.BAD_REQUEST, message);
        }
        return version;
    }

    private List<Device> lockRolloutDevices(Long rolloutId) {
        List<String> deviceIds = members.findDeviceIdsByRolloutIdOrderByDeviceId(rolloutId);
        if (deviceIds.isEmpty()) return List.of();
        List<Device> lockedDevices = devices.lockAllById(deviceIds);
        if (lockedDevices.size() != deviceIds.size()) throw conflict("一个或多个 rollout 设备不存在");
        return lockedDevices;
    }

    private void ensureDevicesAvailable(Long rolloutId, List<Device> lockedDevices) {
        if (lockedDevices.isEmpty()) return;
        List<String> deviceIds = lockedDevices.stream().map(Device::getId).toList();
        long conflicts = members.countConflictingRollouts(
                rolloutId, deviceIds, DEVICE_RESERVING_ROLLOUTS,
                AgentRollout.Status.CANCELED,
                Set.of(AgentRolloutMember.Status.QUEUED, AgentRolloutMember.Status.ACCEPTED,
                        AgentRolloutMember.Status.ROLLBACK_QUEUED,
                        AgentRolloutMember.Status.ROLLBACK_ACCEPTED));
        if (conflicts > 0) {
            throw conflict("一个或多个设备已被其他活动中的 Agent rollout 占用");
        }
    }

    private String displayVersion(String version) {
        return version == null || version.isBlank() ? "未上报" : version;
    }

    private AgentRollout require(Long id) {
        return rollouts.findById(id).orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "Agent rollout 不存在"));
    }

    private AgentRollout lock(Long id) {
        return rollouts.lockById(id).orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "Agent rollout 不存在"));
    }

    private ApiException conflict(String message) {
        return new ApiException(HttpStatus.CONFLICT, message);
    }

    private int value(Integer supplied, int fallback) {
        return supplied == null ? fallback : supplied;
    }

    private String normalizeActor(String actor) {
        String value = actor == null || actor.isBlank() ? "system" : actor.trim();
        return value.length() <= 64 ? value : value.substring(0, 64);
    }

    private String cleanReason(String reason, String fallback) {
        String value = reason == null || reason.isBlank() ? fallback : reason.trim();
        return trim(value, 500);
    }

    private String trim(String value, int max) {
        return value.length() <= max ? value : value.substring(0, max);
    }

    private AgentRolloutDtos.View view(AgentRollout rollout, List<AgentRolloutMember> rolloutMembers) {
        Integer rollbackTotal = rollout.getRollbackStartedAt() == null ? null : Math.toIntExact(
                rolloutMembers.stream().filter(AgentRolloutMember::isRollbackParticipant).count());
        List<AgentRolloutDtos.MemberView> memberViews = rolloutMembers.stream().map(member ->
                new AgentRolloutDtos.MemberView(
                        member.getId(), member.getDevice().getId(), member.getDevice().getName(),
                        member.getPreviousVersion(), member.getRingNumber(), member.getOrderIndex(),
                        member.getEligibleAt(), member.getTask() == null ? null : member.getTask().getId(),
                        member.getStatus(), member.getAttempt(), member.getQueuedAt(), member.getError(),
                        member.getConfirmedAt())).toList();
        return new AgentRolloutDtos.View(
                rollout.getId(), rollout.getTargetVersion(),
                rollout.getMaintenanceWindow() == null ? null : rollout.getMaintenanceWindow().getId(),
                rollout.getCanaryPercent(), rollout.getRingCount(), rollout.getCurrentRing(),
                rollout.getMaxConcurrent(), rollout.getJitterSeconds(), rollout.getFailureThreshold(),
                rollout.getVerificationTimeoutSeconds(), rollout.getStatus(), rollout.getStatusReason(),
                rollout.getCreatedBy(), rollout.getCreatedAt(), rollout.getUpdatedAt(), rollout.getStartedAt(),
                rollout.getCompletedAt(), rollout.getRollbackStartedAt(), rollbackTotal, memberViews);
    }

    private AgentRolloutDtos.View visibleView(AgentRollout rollout, Set<String> visible) {
        List<AgentRolloutMember> rolloutMembers = members.findByRolloutIdOrderByOrderIndex(rollout.getId());
        if (visible != null) {
            rolloutMembers = rolloutMembers.stream()
                    .filter(member -> visible.contains(member.getDevice().getId())).toList();
        }
        return view(rollout, rolloutMembers);
    }
}
