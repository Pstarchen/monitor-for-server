package com.guanlan.monitor.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.config.AppProperties;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientResponseException;

@Service
public class ControllerUpdateService {
    private static final String TOKEN_HEADER = "X-Controller-Update-Token";

    private final AppProperties properties;
    private final ObjectMapper mapper;
    private final RestClient client;

    public ControllerUpdateService(AppProperties properties, ObjectMapper mapper, RestClient.Builder builder) {
        this.properties = properties;
        this.mapper = mapper;
        SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
        requestFactory.setConnectTimeout(5_000);
        requestFactory.setReadTimeout(15_000);
        this.client = builder
                .baseUrl(properties.getControllerUpdate().getServiceUrl())
                .requestFactory(requestFactory)
                .build();
    }

    public JsonNode status() {
        return request(HttpMethod.GET, "/internal/controller-update/status", null);
    }

    public JsonNode check() {
        return request(HttpMethod.POST, "/internal/controller-update/check", null);
    }

    public JsonNode apply() {
        return request(HttpMethod.POST, "/internal/controller-update/apply", null);
    }

    public JsonNode setAutoUpdate(boolean enabled) {
        return request(HttpMethod.PUT, "/internal/controller-update/auto", new AutoUpdateRequest(enabled));
    }

    public JsonNode backupStatus() {
        return request(HttpMethod.GET, "/internal/controller-backup/status", null);
    }

    public JsonNode createBackup() {
        return request(HttpMethod.POST, "/internal/controller-backup/create", null);
    }

    public JsonNode restoreBackup(String name) {
        return request(HttpMethod.POST, "/internal/controller-backup/restore", new BackupRestoreRequest(name));
    }

    public JsonNode setBackupAuto(boolean enabled, int retention) {
        return request(HttpMethod.PUT, "/internal/controller-backup/auto", new BackupAutoRequest(enabled, retention));
    }

    private JsonNode request(HttpMethod method, String path, Object body) {
        String token = properties.getControllerUpdate().getToken();
        if (token == null || token.isBlank()) {
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "系统更新服务尚未配置");
        }
        try {
            RestClient.RequestBodySpec request = client.method(method)
                    .uri(path)
                    .header(TOKEN_HEADER, token)
                    .accept(MediaType.APPLICATION_JSON);
            if (body != null) {
                request.contentType(MediaType.APPLICATION_JSON).body(body);
            }
            JsonNode response = request.retrieve().body(JsonNode.class);
            return response == null ? mapper.createObjectNode() : response;
        } catch (RestClientResponseException exception) {
            if (exception.getStatusCode().value() == HttpStatus.CONFLICT.value()) {
                throw new ApiException(HttpStatus.CONFLICT, responseMessage(exception));
            }
            throw new ApiException(HttpStatus.BAD_GATEWAY, "系统更新服务暂时不可用");
        } catch (ApiException exception) {
            throw exception;
        } catch (Exception exception) {
            throw new ApiException(HttpStatus.BAD_GATEWAY, "系统更新服务暂时不可用");
        }
    }

    private String responseMessage(RestClientResponseException exception) {
        try {
            JsonNode response = mapper.readTree(exception.getResponseBodyAsString());
            String message = response.path("message").asText("").trim();
            return message.isEmpty() ? "已有更新任务正在执行" : message;
        } catch (Exception ignored) {
            return "已有更新任务正在执行";
        }
    }

    private record AutoUpdateRequest(boolean enabled) {}
    private record BackupRestoreRequest(String name) {}
    private record BackupAutoRequest(boolean enabled, int retention) {}
}
