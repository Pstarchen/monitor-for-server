package com.guanlan.monitor.api;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.api.dto.AgentTaskDtos;
import com.guanlan.monitor.api.dto.DeviceDtos;
import com.guanlan.monitor.domain.AgentTask;
import com.guanlan.monitor.security.ApiTokenPrincipal;
import com.guanlan.monitor.service.AgentTaskService;
import com.guanlan.monitor.service.DeviceService;
import com.guanlan.monitor.service.DeviceAccessService;
import com.guanlan.monitor.service.McpRateLimiter;
import jakarta.servlet.http.HttpServletRequest;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.*;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

@RestController
@RequestMapping("/mcp")
@RequiredArgsConstructor
public class McpController {
    private static final int MAX_REQUEST_BYTES = 8 * 1024 * 1024;
    private final ObjectMapper mapper;
    private final DeviceService devices;
    private final DeviceAccessService access;
    private final AgentTaskService tasks;
    private final McpRateLimiter rateLimiter;
    private final com.guanlan.monitor.service.SettingService settings;

    @GetMapping
    ResponseEntity<Void> get() { return ResponseEntity.status(HttpStatus.METHOD_NOT_ALLOWED).build(); }

    @DeleteMapping
    ResponseEntity<Void> delete() { return ResponseEntity.status(HttpStatus.METHOD_NOT_ALLOWED).build(); }

    @PostMapping(consumes = MediaType.APPLICATION_JSON_VALUE, produces = MediaType.APPLICATION_JSON_VALUE)
    ResponseEntity<?> post(Authentication authentication, HttpServletRequest request, @RequestBody String body) {
        if (!settings.mcpEnabled()) return ResponseEntity.notFound().build();
        if (body.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > MAX_REQUEST_BYTES) return ResponseEntity.status(HttpStatus.PAYLOAD_TOO_LARGE).body(Map.of("message", "MCP 请求体过大"));
        if (authentication == null || !(authentication.getPrincipal() instanceof ApiTokenPrincipal principal)) return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body(Map.of("message", "MCP 只接受 API Token"));
        try {
            JsonNode input = mapper.readTree(body);
            if (input == null || !input.isObject()) return jsonRpcError(null, -32600, "Invalid Request");
            JsonNode id = input.get("id");
            String method = text(input.get("method"));
            JsonNode params = input.path("params");
            if (method.isBlank()) return jsonRpcError(id, -32600, "Invalid Request");
            if (!rateLimiter.allow(principal.tokenId())) {
                if ("tools/call".equals(method)) return jsonRpcResult(id, Map.of("content", List.of(Map.of("type", "text", "text", "MCP 请求过于频繁，请稍后重试")), "isError", true));
                return ResponseEntity.status(HttpStatus.TOO_MANY_REQUESTS).body(Map.of("message", "MCP 请求过于频繁，请稍后重试"));
            }
            if ("notifications/initialized".equals(method) && !input.has("id")) return ResponseEntity.status(HttpStatus.ACCEPTED).build();
            return handle(id, method, params, principal, authentication);
        } catch (Exception exception) {
            return jsonRpcError(null, -32700, "Parse error");
        }
    }

    private ResponseEntity<?> handle(JsonNode id, String method, JsonNode params, ApiTokenPrincipal principal, Authentication authentication) {
        return switch (method) {
            case "initialize" -> jsonRpcResult(id, Map.of("protocolVersion", "2024-11-05", "capabilities", Map.of("tools", Map.of()), "serverInfo", Map.of("name", "xingchen-monitor", "version", "1.0")));
            case "ping" -> jsonRpcResult(id, Map.of());
            case "tools/list" -> jsonRpcResult(id, Map.of("tools", toolDefinitions()));
            case "tools/call" -> callTool(id, params, principal, authentication);
            default -> jsonRpcError(id, -32601, "Method not found");
        };
    }

    private ResponseEntity<?> callTool(JsonNode id, JsonNode params, ApiTokenPrincipal principal, Authentication authentication) {
        String name = text(params.get("name"));
        JsonNode arguments = params.path("arguments");
        try {
            Map<String, Object> result = switch (name) {
                case "meta.whoami" -> whoami(principal);
                case "server.list" -> serverList(principal, authentication, arguments);
                case "server.get" -> serverGet(principal, authentication, arguments);
                case "server.exec" -> serverExec(principal, authentication, arguments);
                case "fs.list" -> fileTask(principal, authentication, arguments, AgentTask.Operation.FILE_LIST, "nezha:server:read");
                case "fs.read" -> fileTask(principal, authentication, arguments, AgentTask.Operation.FILE_READ, "nezha:server:read");
                case "fs.write" -> fileTask(principal, authentication, arguments, AgentTask.Operation.FILE_WRITE, "nezha:server:write");
                case "fs.delete" -> fileTask(principal, authentication, arguments, AgentTask.Operation.FILE_DELETE, "nezha:server:delete");
                default -> throw new McpToolException("未知工具: " + name);
            };
            return jsonRpcResult(id, Map.of("structuredContent", result, "content", List.of(Map.of("type", "text", "text", write(result))), "isError", false));
        } catch (McpToolException exception) {
            return jsonRpcResult(id, Map.of("content", List.of(Map.of("type", "text", "text", exception.getMessage())), "isError", true));
        } catch (Exception exception) {
            return jsonRpcResult(id, Map.of("content", List.of(Map.of("type", "text", "text", "工具执行失败")), "isError", true));
        }
    }

    private Map<String, Object> whoami(ApiTokenPrincipal principal) {
        return Map.of("username", principal.getUsername(), "tokenId", principal.tokenId(), "scopes", principal.scopes(), "serverIds", principal.serverIds(), "admin", principal.getAuthorities().stream().anyMatch(value -> value.getAuthority().equals("ROLE_ADMIN")));
    }

    private Map<String, Object> serverList(ApiTokenPrincipal principal, Authentication authentication, JsonNode arguments) throws McpToolException {
        requireScope(principal, "nezha:inventory:read");
        boolean onlineOnly = arguments.path("online_only").asBoolean(false);
        List<Map<String, Object>> result = new ArrayList<>();
        for (DeviceDtos.View device : devices.list()) {
            if (!access.canView(authentication, device.id()) || (onlineOnly && device.status() != com.guanlan.monitor.domain.Device.Status.ONLINE)) continue;
            result.add(Map.of("id", device.id(), "name", device.name(), "status", device.status().name(), "os", value(device.os()), "lastSeenAt", value(device.lastSeenAt())));
        }
        return Map.of("servers", result);
    }

    private Map<String, Object> serverGet(ApiTokenPrincipal principal, Authentication authentication, JsonNode arguments) throws McpToolException {
        requireScope(principal, "nezha:server:read");
        String id = text(arguments.get("server_id"));
        if (id.isBlank() || !access.canView(authentication, id)) throw new McpToolException("无权访问该服务器");
        DeviceDtos.View device = devices.get(id);
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("id", device.id()); result.put("name", device.name()); result.put("status", device.status().name()); result.put("hostname", value(device.hostname())); result.put("os", value(device.os())); result.put("architecture", value(device.architecture())); result.put("lastSeenAt", value(device.lastSeenAt())); result.put("latest", value(device.latest()));
        return result;
    }

    private Map<String, Object> serverExec(ApiTokenPrincipal principal, Authentication authentication, JsonNode arguments) throws McpToolException {
        requireScope(principal, "nezha:server:exec");
        String id = text(arguments.get("server_id"));
        String command = text(arguments.get("cmd"));
        if (id.isBlank() || command.isBlank() || !access.canTask(authentication, id)) throw new McpToolException("服务器、命令或设备权限无效");
        List<String> args = new ArrayList<>();
        arguments.path("args").forEach(value -> args.add(value.asText()));
        int timeout = arguments.path("timeout_seconds").asInt(30);
        int output = arguments.path("max_output_bytes").asInt(65536);
        try {
            AgentTaskDtos.View task = tasks.create(new AgentTaskDtos.CreateRequest(id, command, args, timeout, output), principal.getUsername(), authentication);
            return Map.of("taskId", task.id(), "status", task.status().name(), "message", "任务已排队，Agent 领取后返回结果");
        } catch (ApiException exception) {
            throw new McpToolException(exception.getMessage());
        }
    }

    private Map<String, Object> fileTask(ApiTokenPrincipal principal, Authentication authentication, JsonNode arguments,
                                         AgentTask.Operation operation, String scope) throws McpToolException {
        requireScope(principal, scope);
        String id = text(arguments.get("server_id"));
        String path = text(arguments.get("path"));
        if (id.isBlank() || path.isBlank() || !access.canTask(authentication, id)) throw new McpToolException("服务器、路径或设备权限无效");
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("path", path);
        switch (operation) {
            case FILE_LIST -> payload.put("showHidden", arguments.path("show_hidden").asBoolean(false));
            case FILE_READ -> {
                payload.put("offset", arguments.path("offset").asLong(0));
                payload.put("length", arguments.path("length").asInt(65536));
                payload.put("encoding", text(arguments.get("encoding")));
            }
            case FILE_WRITE -> {
                payload.put("content", rawText(arguments.get("content")));
                payload.put("encoding", text(arguments.get("encoding")));
                payload.put("mode", text(arguments.get("mode")));
                payload.put("createDirs", arguments.path("create_dirs").asBoolean(false));
                payload.put("ifMatchSha256", text(arguments.get("if_match_sha256")));
            }
            case FILE_DELETE -> payload.put("recursive", arguments.path("recursive").asBoolean(false));
            default -> throw new McpToolException("文件工具无效");
        }
        int timeout = arguments.path("timeout_seconds").asInt(30);
        int output = arguments.path("max_output_bytes").asInt(65536);
        try {
            AgentTaskDtos.View task = tasks.createFile(id, operation, payload, timeout, output, principal.getUsername(), authentication);
            AgentTaskDtos.View completed = tasks.waitForCompletion(task.id(), Math.min(timeout * 1000L + 1000L, 3_000L));
            Map<String, Object> result = new LinkedHashMap<>();
            result.put("taskId", completed.id()); result.put("operation", operation.name()); result.put("status", completed.status().name());
            if (completed.status() == AgentTask.Status.SUCCEEDED && completed.stdout() != null && !completed.stdout().isBlank()) {
                try { result.put("data", mapper.readTree(completed.stdout())); }
                catch (Exception ignored) { result.put("stdout", completed.stdout()); }
            } else if (completed.error() != null && !completed.error().isBlank()) {
                result.put("error", completed.error());
            }
            return result;
        } catch (ApiException exception) {
            throw new McpToolException(exception.getMessage());
        }
    }

    private List<Map<String, Object>> toolDefinitions() {
        return List.of(
                tool("meta.whoami", "查看当前 API Token", Map.of("type", "object", "properties", Map.of())),
                tool("server.list", "列出 Token 可见服务器", Map.of("type", "object", "properties", Map.of("online_only", Map.of("type", "boolean")))),
                tool("server.get", "读取服务器状态", objectSchema(Map.of("server_id", Map.of("type", "string")), List.of("server_id"))),
                tool("server.exec", "向服务器排队一次性命令", objectSchema(Map.of("server_id", Map.of("type", "string"), "cmd", Map.of("type", "string"), "args", Map.of("type", "array", "items", Map.of("type", "string")), "timeout_seconds", Map.of("type", "integer", "minimum", 1, "maximum", 300), "max_output_bytes", Map.of("type", "integer", "minimum", 1024, "maximum", 1048576)), List.of("server_id", "cmd"))),
                tool("fs.list", "列出服务器目录", objectSchema(Map.of("server_id", Map.of("type", "string"), "path", Map.of("type", "string"), "show_hidden", Map.of("type", "boolean")), List.of("server_id", "path"))),
                tool("fs.read", "读取服务器文件并返回排队任务", objectSchema(Map.of("server_id", Map.of("type", "string"), "path", Map.of("type", "string"), "offset", Map.of("type", "integer"), "length", Map.of("type", "integer"), "encoding", Map.of("type", "string", "enum", List.of("utf8", "base64"))), List.of("server_id", "path"))),
                tool("fs.write", "原子写入服务器文件", objectSchema(Map.of("server_id", Map.of("type", "string"), "path", Map.of("type", "string"), "content", Map.of("type", "string"), "encoding", Map.of("type", "string"), "mode", Map.of("type", "string"), "create_dirs", Map.of("type", "boolean"), "if_match_sha256", Map.of("type", "string")), List.of("server_id", "path", "content"))),
                tool("fs.delete", "删除服务器文件或目录", objectSchema(Map.of("server_id", Map.of("type", "string"), "path", Map.of("type", "string"), "recursive", Map.of("type", "boolean")), List.of("server_id", "path")))
        );
    }

    private Map<String, Object> tool(String name, String description, Map<String, Object> schema) { return Map.of("name", name, "description", description, "inputSchema", schema, "outputSchema", Map.of("type", "object")); }
    private Map<String, Object> objectSchema(Map<String, Object> properties, List<String> required) { return Map.of("type", "object", "properties", properties, "required", required); }
    private void requireScope(ApiTokenPrincipal principal, String scope) throws McpToolException { if (!principal.allowsScope(scope)) throw new McpToolException("API Token 缺少所需权限: " + scope); }
    private Object value(Object value) { return value == null ? "" : value; }
    private String text(JsonNode node) { return node == null || node.isNull() ? "" : node.asText("").trim(); }
    private String rawText(JsonNode node) { return node == null || node.isNull() ? "" : node.asText(""); }
    private String write(Object value) { try { return mapper.writeValueAsString(value); } catch (Exception ignored) { return "{}"; } }
    private ResponseEntity<?> jsonRpcResult(JsonNode id, Object result) {
        Map<String, Object> response = new LinkedHashMap<>(); response.put("jsonrpc", "2.0"); response.put("id", id); response.put("result", result); return ResponseEntity.ok(response);
    }
    private ResponseEntity<?> jsonRpcError(JsonNode id, int code, String message) {
        Map<String, Object> response = new LinkedHashMap<>(); response.put("jsonrpc", "2.0"); response.put("id", id); response.put("error", Map.of("code", code, "message", message)); return ResponseEntity.ok(response);
    }
    private static final class McpToolException extends Exception { McpToolException(String message) { super(message); } }
}
