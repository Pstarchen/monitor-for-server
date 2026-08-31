package com.guanlan.monitor.service;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.api.dto.AgentTaskDtos;
import com.guanlan.monitor.domain.AgentTask;
import com.guanlan.monitor.domain.Device;
import com.guanlan.monitor.repository.AgentTaskRepository;
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

@Service
@RequiredArgsConstructor
public class AgentTaskService {
    private static final TypeReference<List<String>> STRING_LIST = new TypeReference<>() {};
    private static final int DEFAULT_TIMEOUT_SECONDS = 30;
    private static final int DEFAULT_MAX_OUTPUT_BYTES = 65_536;
    private static final int MAX_COMMAND_LENGTH = 128;
    private static final int MAX_FILE_PATH_LENGTH = 4096;
    private static final int MAX_FILE_CONTENT_LENGTH = 1_500_000;
    private final AgentTaskRepository tasks;
    private final DeviceService devices;
    private final ObjectMapper mapper;
    private final AuditService audit;
    private final DeviceAccessService access;

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
        if (operation == null || operation == AgentTask.Operation.COMMAND) {
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

    private AgentTaskDtos.View view(AgentTask task) {
        return new AgentTaskDtos.View(task.getId(), task.getDevice().getId(), task.getDevice().getName(), task.getOperation(), task.getCommand(), parse(task.getArgsJson()), task.getTimeoutSeconds(), task.getMaxOutputBytes(), task.getStatus(), task.getCreatedBy(), task.getCreatedAt(), task.getStartedAt(), task.getFinishedAt(), task.getExitCode(), task.getStdout(), task.getStderr(), task.getError());
    }
}
