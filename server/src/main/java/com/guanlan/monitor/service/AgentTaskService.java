package com.guanlan.monitor.service;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.api.dto.AgentTaskDtos;
import com.guanlan.monitor.domain.AgentTask;
import com.guanlan.monitor.domain.AgentRollout;
import com.guanlan.monitor.domain.AgentRolloutMember;
import com.guanlan.monitor.domain.Device;
import com.guanlan.monitor.repository.AgentRolloutMemberRepository;
import com.guanlan.monitor.repository.AgentRolloutRepository;
import com.guanlan.monitor.repository.AgentTaskRepository;
import com.guanlan.monitor.repository.DeviceRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.PageRequest;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.Authentication;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.regex.Pattern;

@Service
@RequiredArgsConstructor
public class AgentTaskService {
    private static final TypeReference<List<String>> STRING_LIST = new TypeReference<>() {};
    private static final int DEFAULT_TIMEOUT_SECONDS = 30;
    private static final int DEFAULT_MAX_OUTPUT_BYTES = 65_536;
    private static final int MAX_COMMAND_LENGTH = 128;
    private static final int MAX_FILE_PATH_LENGTH = 4096;
    private static final int MAX_FILE_CONTENT_LENGTH = 1_500_000;
    private static final int UPDATE_TIMEOUT_SECONDS = 300;
    private static final int UPDATE_MAX_OUTPUT_BYTES = 16_384;
    private static final Pattern STABLE_VERSION = Pattern.compile("^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$");
    private static final Set<AgentRolloutMember.Status> ACTIVE_UPDATE_STATUSES = Set.of(
            AgentRolloutMember.Status.QUEUED, AgentRolloutMember.Status.ACCEPTED,
            AgentRolloutMember.Status.ROLLBACK_QUEUED, AgentRolloutMember.Status.ROLLBACK_ACCEPTED);
    private final AgentTaskRepository tasks;
    private final AgentRolloutRepository rollouts;
    private final AgentRolloutMemberRepository rolloutMembers;
    private final DeviceRepository deviceRepository;
    private final DeviceService devices;
    private final ObjectMapper mapper;
    private final AuditService audit;
    private final DeviceAccessService access;
    private final MaintenanceWindowService maintenanceWindows;

    @Transactional
    public AgentTaskDtos.View create(AgentTaskDtos.CreateRequest request, String actor, Authentication authentication) {
        Device device = devices.require(request.deviceId());
        access.requireTask(authentication, device.getId());
        String command = normalizeCommand(request.command());
        List<String> args = normalizeArgs(request.args());
        int timeout = request.timeoutSeconds() == null ? DEFAULT_TIMEOUT_SECONDS : request.timeoutSeconds();
        int maxOutput = request.maxOutputBytes() == null ? DEFAULT_MAX_OUTPUT_BYTES : request.maxOutputBytes();
        validateLimits(timeout, maxOutput);

        AgentTask task = new AgentTask();
        task.setDevice(device);
        task.setOperation(AgentTask.Operation.COMMAND);
        task.setCommand(command);
        task.setArgsJson(json(args));
        task.setTimeoutSeconds(timeout);
        task.setMaxOutputBytes(maxOutput);
        task.setCreatedBy(actor);
        tasks.save(task);
        audit.record("AGENT_TASK_CREATE", "task:" + task.getId(), "为设备 " + device.getName() + " 创建命令任务");
        return view(task);
    }

    @Transactional
    public AgentTaskDtos.View createFile(String deviceId, AgentTask.Operation operation, Map<String, Object> payload,
                                         Integer timeoutSeconds, Integer maxOutputBytes, String actor,
                                         Authentication authentication) {
        if (operation == null || operation == AgentTask.Operation.COMMAND || operation == AgentTask.Operation.AGENT_UPDATE) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "文件任务类型无效");
        }
        Device device = devices.require(deviceId);
        access.requireTask(authentication, device.getId());
        Map<String, Object> normalized = normalizeFilePayload(operation, payload);
        int timeout = timeoutSeconds == null ? DEFAULT_TIMEOUT_SECONDS : timeoutSeconds;
        int maxOutput = maxOutputBytes == null ? DEFAULT_MAX_OUTPUT_BYTES : maxOutputBytes;
        validateLimits(timeout, maxOutput);

        AgentTask task = new AgentTask();
        task.setDevice(device);
        task.setOperation(operation);
        task.setCommand("file." + operation.name().toLowerCase(Locale.ROOT));
        task.setArgsJson("[]");
        task.setPayloadJson(jsonObject(normalized));
        task.setTimeoutSeconds(timeout);
        task.setMaxOutputBytes(maxOutput);
        task.setCreatedBy(actor);
        tasks.save(task);
        audit.record("AGENT_FILE_TASK_CREATE", "task:" + task.getId(), "为设备 " + device.getName() + " 创建文件任务 " + operation.name());
        return view(task);
    }

    @Transactional
    public AgentTaskDtos.View createUpdate(AgentTaskDtos.UpdateRequest request, String actor,
                                           Authentication authentication) {
        if (request != null) access.requireTask(authentication, request.deviceId());
        return createUpdateAt(request, actor, Instant.now());
    }

    @Transactional
    public AgentTaskDtos.View createUpdateAt(AgentTaskDtos.UpdateRequest request, String actor, Instant now) {
        if (request == null || !request.unknownFields().isEmpty()) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "Agent 更新请求包含未知字段");
        }
        String action = request.action();
        String version = request.version();
        if ((!"update".equals(action) && !"rollback".equals(action))
                || version == null || !STABLE_VERSION.matcher(version).matches()) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "Agent 更新动作或版本无效");
        }
        if (request.rolloutId() == null || request.memberId() == null
                || request.rolloutId() < 1 || request.memberId() < 1
                || request.deviceId() == null || request.deviceId().isBlank()
                || !request.deviceId().equals(request.deviceId().trim())) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "Agent 更新目标无效");
        }

        AgentRollout rollout = rollouts.lockById(request.rolloutId())
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "Agent rollout 不存在"));
        Device lockedDevice = deviceRepository.lockAllById(List.of(request.deviceId())).stream().findFirst()
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "设备不存在"));
        AgentRolloutMember member = rolloutMembers.lockById(request.memberId())
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "Agent rollout 成员不存在"));
        if (!member.getRollout().getId().equals(rollout.getId())
                || !member.getDevice().getId().equals(request.deviceId())) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "Agent rollout 成员与目标不匹配");
        }

        boolean rollback = action.equals("rollback");
        AgentRollout.Status requiredRolloutStatus = rollback
                ? AgentRollout.Status.ROLLING_BACK : AgentRollout.Status.RUNNING;
        AgentRolloutMember.Status requiredMemberStatus = rollback
                ? AgentRolloutMember.Status.ROLLBACK_PENDING : AgentRolloutMember.Status.PENDING;
        String expectedVersion = rollback ? member.getPreviousVersion() : rollout.getTargetVersion();
        if (rollout.getStatus() != requiredRolloutStatus
                || member.getStatus() != requiredMemberStatus
                || member.getRingNumber() != rollout.getCurrentRing()
                || !expectedVersion.equals(version)) {
            throw new ApiException(HttpStatus.CONFLICT, "Agent rollout 当前不允许派发该任务");
        }
        if (rollback && !rollout.getTargetVersion().equals(lockedDevice.getAgentVersion())) {
            throw new ApiException(HttpStatus.CONFLICT,
                    "设备 Agent 版本已变化，拒绝派发旧 rollout 的降级回滚任务");
        }
        if (member.getEligibleAt() == null || member.getEligibleAt().isAfter(now)) {
            throw new ApiException(HttpStatus.CONFLICT, "Agent rollout 成员尚未到达派发时间");
        }
        if (rollout.getMaintenanceWindow() != null
                && !maintenanceWindows.isActive(rollout.getMaintenanceWindow(), now)) {
            throw new ApiException(HttpStatus.CONFLICT, "当前不在 Agent rollout 维护窗口内");
        }
        long active = rolloutMembers.countByRolloutIdAndStatusIn(rollout.getId(), ACTIVE_UPDATE_STATUSES);
        if (active >= rollout.getMaxConcurrent()) {
            throw new ApiException(HttpStatus.CONFLICT, "Agent rollout 已达到并发上限");
        }

        Device device = lockedDevice;
        AgentTask task = new AgentTask();
        task.setDevice(device);
        task.setOperation(AgentTask.Operation.AGENT_UPDATE);
        task.setCommand("agent.update");
        task.setArgsJson("[]");
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("action", action);
        payload.put("version", version);
        payload.put("rolloutId", rollout.getId());
        payload.put("memberId", member.getId());
        task.setPayloadJson(jsonObject(payload));
        task.setTimeoutSeconds(UPDATE_TIMEOUT_SECONDS);
        task.setMaxOutputBytes(UPDATE_MAX_OUTPUT_BYTES);
        task.setCreatedBy(normalizeActor(actor));
        tasks.save(task);

        member.setTask(task);
        member.setStatus(rollback ? AgentRolloutMember.Status.ROLLBACK_QUEUED : AgentRolloutMember.Status.QUEUED);
        member.setQueuedAt(now);
        member.setAttempt(member.getAttempt() + 1);
        member.setError(null);
        member.setConfirmedAt(null);
        audit.record("AGENT_UPDATE_TASK_CREATE", "task:" + task.getId(),
                "为 rollout " + rollout.getId() + " 的设备 " + device.getName() + " 派发 " + action + " 任务");
        return view(task);
    }

    @Transactional(readOnly = true)
    public List<AgentTaskDtos.View> list(String deviceId, int limit, Authentication authentication) {
        if (deviceId != null && !deviceId.isBlank()) access.requireView(authentication, deviceId);
        PageRequest page = PageRequest.of(0, Math.min(Math.max(limit, 1), 200));
        List<AgentTaskDtos.View> result = (deviceId == null || deviceId.isBlank()
                ? tasks.findAllByOrderByCreatedAtDesc(page)
                : tasks.findAllByDeviceIdOrderByCreatedAtDesc(deviceId, page))
                .stream().map(this::view).toList();
        Set<String> visible = access.visibleDeviceIds(authentication);
        return visible == null ? result : result.stream().filter(task -> visible.contains(task.deviceId())).toList();
    }

    @Transactional(readOnly = true)
    public AgentTaskDtos.View get(Long id, Authentication authentication) {
        AgentTaskDtos.View result = view(require(id));
        access.requireView(authentication, result.deviceId());
        return result;
    }

    public AgentTaskDtos.View waitForCompletion(Long id, long timeoutMillis) {
        long deadline = System.currentTimeMillis() + Math.max(0, Math.min(timeoutMillis, 15_000));
        AgentTaskDtos.View current;
        do {
            current = getInternal(id);
            if (current.status() != AgentTask.Status.QUEUED && current.status() != AgentTask.Status.RUNNING) return current;
            if (System.currentTimeMillis() >= deadline) return current;
            try { Thread.sleep(100); } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); return current; }
        } while (true);
    }

    @Transactional
    public void cancel(Long id, String actor, Authentication authentication) {
        AgentTask task = require(id);
        access.requireTask(authentication, task.getDevice().getId());
        if (task.getOperation() == AgentTask.Operation.AGENT_UPDATE) {
            throw new ApiException(HttpStatus.CONFLICT, "Agent 更新任务必须通过 rollout 管理，不能单独取消");
        }
        if (task.getStatus() == AgentTask.Status.QUEUED || task.getStatus() == AgentTask.Status.RUNNING) {
            task.setStatus(AgentTask.Status.CANCELED);
            task.setFinishedAt(Instant.now());
            task.setError("任务已由 " + actor + " 取消");
            audit.record("AGENT_TASK_CANCEL", "task:" + id, "取消 Agent 命令任务");
        }
    }

    @Transactional
    public Optional<AgentTaskDtos.Assignment> claimNext(String deviceId) {
        devices.require(deviceId);
        List<AgentTask> queued = tasks.findQueuedForDevice(deviceId, AgentTask.Status.QUEUED, PageRequest.of(0, 1));
        if (queued.isEmpty()) return Optional.empty();
        AgentTask task = queued.get(0);
        task.setStatus(AgentTask.Status.RUNNING);
        task.setStartedAt(Instant.now());
        return Optional.of(new AgentTaskDtos.Assignment(task.getId(), task.getOperation(), task.getCommand(), parse(task.getArgsJson()), task.getTimeoutSeconds(), task.getMaxOutputBytes(), parseObject(task.getPayloadJson())));
    }

    @Transactional
    public AgentTaskDtos.View complete(String deviceId, Long id, AgentTaskDtos.ResultRequest request) {
        AgentTask task = require(id);
        if (!task.getDevice().getId().equals(deviceId)) {
            throw new ApiException(HttpStatus.FORBIDDEN, "任务不属于当前设备");
        }
        if (task.getStatus() != AgentTask.Status.RUNNING) {
            throw new ApiException(HttpStatus.CONFLICT, "任务当前不接受结果");
        }
        AgentTask.Status status = parseResultStatus(request.status());
        task.setStatus(status);
        task.setFinishedAt(Instant.now());
        task.setExitCode(request.exitCode());
        task.setStdout(limitUtf8(request.stdout(), task.getMaxOutputBytes()));
        task.setStderr(limitUtf8(request.stderr(), task.getMaxOutputBytes()));
        task.setError(trim(request.error(), 500));
        audit.record("AGENT_TASK_RESULT", "task:" + id, "Agent 返回命令任务结果 " + status.name());
        return view(task);
    }

    private AgentTask require(Long id) {
        return tasks.findById(id).orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "任务不存在"));
    }

    @Transactional(readOnly = true)
    protected AgentTaskDtos.View getInternal(Long id) {
        return tasks.findWithDevice(id).map(this::view)
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "任务不存在"));
    }

    private AgentTask.Status parseResultStatus(String value) {
        try {
            AgentTask.Status status = AgentTask.Status.valueOf(value.trim().toUpperCase(Locale.ROOT));
            if (status == AgentTask.Status.SUCCEEDED || status == AgentTask.Status.FAILED || status == AgentTask.Status.TIMED_OUT) return status;
        } catch (Exception ignored) { }
        throw new ApiException(HttpStatus.BAD_REQUEST, "任务结果状态无效");
    }

    private String normalizeCommand(String value) {
        String command = value == null ? "" : value.trim();
        if (command.isBlank() || command.length() > MAX_COMMAND_LENGTH || command.indexOf('\u0000') >= 0) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "命令不能为空或超出长度限制");
        }
        if (command.equalsIgnoreCase("agent.update")) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "该命令仅允许通过专用 Agent 更新协议派发");
        }
        return command;
    }

    private List<String> normalizeArgs(List<String> values) {
        if (values == null || values.size() > 32) throw new ApiException(HttpStatus.BAD_REQUEST, "命令参数数量无效");
        return values.stream().map(value -> {
            if (value == null || value.indexOf('\u0000') >= 0 || value.length() > 256) throw new ApiException(HttpStatus.BAD_REQUEST, "命令参数无效");
            return value;
        }).toList();
    }

    private void validateLimits(int timeout, int maxOutput) {
        if (timeout < 1 || timeout > 300 || maxOutput < 1024 || maxOutput > 1_048_576) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "任务超时或输出上限无效");
        }
    }

    private String json(List<String> value) {
        try { return mapper.writeValueAsString(value); }
        catch (JsonProcessingException exception) { throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "任务参数保存失败"); }
    }

    private String jsonObject(Map<String, Object> value) {
        try { return mapper.writeValueAsString(value); }
        catch (JsonProcessingException exception) { throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "文件任务参数保存失败"); }
    }

    private com.fasterxml.jackson.databind.JsonNode parseObject(String value) {
        try { return value == null || value.isBlank() ? mapper.createObjectNode() : mapper.readTree(value); }
        catch (Exception exception) { return mapper.createObjectNode(); }
    }

    private Map<String, Object> normalizeFilePayload(AgentTask.Operation operation, Map<String, Object> input) {
        Map<String, Object> payload = new LinkedHashMap<>();
        String path = string(input, "path");
        if (path.isBlank() || path.length() > MAX_FILE_PATH_LENGTH || path.indexOf('\u0000') >= 0) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "文件路径无效");
        }
        payload.put("path", path);
        switch (operation) {
            case FILE_LIST -> payload.put("showHidden", bool(input, "showHidden"));
            case FILE_READ -> {
                long offset = number(input, "offset", 0);
                int length = (int) number(input, "length", Math.min(DEFAULT_MAX_OUTPUT_BYTES, 1_048_576));
                if (offset < 0 || length < 1 || length > 1_048_576) throw new ApiException(HttpStatus.BAD_REQUEST, "文件读取范围无效");
                payload.put("offset", offset); payload.put("length", length);
                String encoding = string(input, "encoding").toLowerCase(Locale.ROOT);
                if (encoding.isBlank()) encoding = "utf8";
                if (!encoding.equals("utf8") && !encoding.equals("base64")) throw new ApiException(HttpStatus.BAD_REQUEST, "文件编码无效");
                payload.put("encoding", encoding);
            }
            case FILE_WRITE -> {
                String content = string(input, "content");
                if (content.length() > MAX_FILE_CONTENT_LENGTH) throw new ApiException(HttpStatus.BAD_REQUEST, "文件内容过大");
                String encoding = string(input, "encoding").toLowerCase(Locale.ROOT);
                if (encoding.isBlank()) encoding = "utf8";
                if (!encoding.equals("utf8") && !encoding.equals("base64")) throw new ApiException(HttpStatus.BAD_REQUEST, "文件编码无效");
                String hash = string(input, "ifMatchSha256").toLowerCase(Locale.ROOT);
                if (!hash.isBlank() && !hash.matches("[0-9a-f]{64}")) throw new ApiException(HttpStatus.BAD_REQUEST, "文件校验值无效");
                payload.put("content", content); payload.put("encoding", encoding);
                payload.put("createDirs", bool(input, "createDirs")); payload.put("mode", string(input, "mode"));
                payload.put("ifMatchSha256", hash);
            }
            case FILE_DELETE -> payload.put("recursive", bool(input, "recursive"));
            default -> throw new ApiException(HttpStatus.BAD_REQUEST, "文件任务类型无效");
        }
        return payload;
    }

    private String string(Map<String, Object> input, String key) { Object value = input == null ? null : input.get(key); return value == null ? "" : String.valueOf(value); }
    private boolean bool(Map<String, Object> input, String key) { Object value = input == null ? null : input.get(key); return value instanceof Boolean b && b; }
    private long number(Map<String, Object> input, String key, long fallback) { Object value = input == null ? null : input.get(key); return value instanceof Number n ? n.longValue() : fallback; }

    private List<String> parse(String value) {
        try { return mapper.readValue(value, STRING_LIST); }
        catch (Exception exception) { return List.of(); }
    }

    private String limitUtf8(String value, int maxBytes) {
        if (value == null || value.isEmpty()) return "";
        byte[] bytes = value.getBytes(StandardCharsets.UTF_8);
        if (bytes.length <= maxBytes) return value;
        int end = maxBytes;
        while (end > 0 && (bytes[end] & 0xc0) == 0x80) end--;
        return new String(bytes, 0, end, StandardCharsets.UTF_8);
    }

    private String trim(String value, int max) {
        if (value == null) return "";
        return value.length() <= max ? value : value.substring(0, max);
    }

    private String normalizeActor(String actor) {
        String value = actor == null || actor.isBlank() ? "system" : actor.trim();
        return value.length() <= 64 ? value : value.substring(0, 64);
    }

    private AgentTaskDtos.View view(AgentTask task) {
        return new AgentTaskDtos.View(task.getId(), task.getDevice().getId(), task.getDevice().getName(), task.getOperation(), task.getCommand(), parse(task.getArgsJson()), task.getTimeoutSeconds(), task.getMaxOutputBytes(), task.getStatus(), task.getCreatedBy(), task.getCreatedAt(), task.getStartedAt(), task.getFinishedAt(), task.getExitCode(), task.getStdout(), task.getStderr(), task.getError());
    }
}
