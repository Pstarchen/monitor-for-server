package com.guanlan.monitor.push;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.service.PushKitConfigurationService;
import com.guanlan.monitor.config.PushKitProperties;
import org.springframework.http.MediaType;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientResponseException;

import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.Set;

@Component
public class PushKitClient {
    private static final Set<String> RETRYABLE_CODES = Set.of("80200005", "80300029", "81000001");
    private final PushKitConfigurationService configurations;
    private final PushKitServiceAccount serviceAccount;
    private final RestClient client;
    private final ObjectMapper mapper;

    public PushKitClient(PushKitProperties properties, PushKitServiceAccount serviceAccount,
                         RestClient.Builder builder, ObjectMapper mapper) {
        this(new PushKitConfigurationService(properties), serviceAccount, builder, mapper);
    }

    @Autowired
    public PushKitClient(PushKitConfigurationService configurations, PushKitServiceAccount serviceAccount,
                         RestClient.Builder builder, ObjectMapper mapper) {
        this.configurations = configurations;
        this.serviceAccount = serviceAccount;
        this.client = builder.requestFactory(requestFactory()).build();
        this.mapper = mapper;
    }

    public boolean enabled() {
        return configurations.runtime().enabled();
    }

    public SendResult send(String token, String title, String body, String dataJson, boolean testMessage) {
        PushKitConfigurationService.Runtime runtime = configurations.runtime();
        requireConfigured(runtime);
        try {
            PushResponse response = client.post().uri(serviceAccount.sendUri(runtime))
                    .contentType(MediaType.APPLICATION_JSON)
                    .header("Authorization", "Bearer " + serviceAccount.jwt(runtime))
                    .header("push-type", "0")
                    .body(requestBody(runtime, token, title, body, dataJson, testMessage))
                    .retrieve().body(PushResponse.class);
            if (response == null || blank(response.code())) {
                throw new PushKitException("Huawei Push Kit response was invalid", true, false, null);
            }
            if ("80000000".equals(response.code())) {
                return new SendResult(limit(response.requestId(), 128));
            }
            if ("80200005".equals(response.code())) serviceAccount.invalidateJwt();
            throw new PushKitException("Huawei Push Kit rejected the message with code " + safeCode(response.code()),
                    RETRYABLE_CODES.contains(response.code()), invalidToken(response), null);
        } catch (RestClientResponseException exception) {
            int status = exception.getStatusCode().value();
            if (status == 401) serviceAccount.invalidateJwt();
            throw new PushKitException("Huawei Push Kit request was rejected with HTTP " + status,
                    status == 401 || status == 408 || status == 425 || status == 429 || status >= 500,
                    false, exception);
        } catch (PushKitException exception) {
            throw exception;
        } catch (Exception exception) {
            throw new PushKitException("Huawei Push Kit request failed", true, false, exception);
        }
    }

    Map<String, Object> requestBody(PushKitConfigurationService.Runtime runtime, String token, String title, String body,
                                    String dataJson, boolean testMessage) throws Exception {
        JsonNode data = mapper.readTree(dataJson == null || dataJson.isBlank() ? "{}" : dataJson);
        if (!data.isObject()) throw new IllegalArgumentException("Push data must be a JSON object");
        Map<String, Object> notification = Map.of(
                "category", runtime.category(),
                "title", title,
                "body", body,
                "clickAction", Map.of("actionType", 0, "data", data),
                "foregroundShow", true);
        return Map.of(
                "payload", Map.of("notification", notification),
                "target", Map.of("token", List.of(token)),
                "pushOptions", Map.of(
                        "testMessage", testMessage,
                        "ttl", runtime.ttlSeconds()));
    }

    Map<String, Object> requestBody(String token, String title, String body,
                                    String dataJson, boolean testMessage) throws Exception {
        return requestBody(configurations.runtime(), token, title, body, dataJson, testMessage);
    }

    private boolean invalidToken(PushResponse response) {
        if (!"80100000".equals(response.code()) && !"80300007".equals(response.code())) return false;
        String message = response.msg() == null ? "" : response.msg();
        return message.contains("tokenFormatError") || message.contains("tokenPlatformNotSupport");
    }

    private void requireConfigured(PushKitConfigurationService.Runtime runtime) {
        if (!runtime.enabled()) {
            throw new PushKitException("Huawei Push Kit is disabled", false, false, null);
        }
        try {
            serviceAccount.validate(runtime);
        } catch (IllegalStateException exception) {
            throw new PushKitException("Huawei Push Kit is enabled but not fully configured", false, false, exception);
        }
    }

    private String safeCode(String value) {
        return value == null || !value.matches("^[0-9]{8}$") ? "UNKNOWN" : value;
    }

    private String limit(String value, int max) {
        if (value == null) return "";
        return value.length() <= max ? value : value.substring(0, max);
    }

    private boolean blank(String value) {
        return value == null || value.isBlank();
    }

    private static SimpleClientHttpRequestFactory requestFactory() {
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout(Duration.ofSeconds(5));
        factory.setReadTimeout(Duration.ofSeconds(10));
        return factory;
    }

    private record PushResponse(String code, String msg, String requestId) {}
    public record SendResult(String providerRequestId) {}

    public static final class PushKitException extends RuntimeException {
        private final boolean retryable;
        private final boolean invalidToken;

        PushKitException(String message, boolean retryable, boolean invalidToken, Throwable cause) {
            super(message, cause);
            this.retryable = retryable;
            this.invalidToken = invalidToken;
        }

        public boolean retryable() { return retryable; }
        public boolean invalidToken() { return invalidToken; }
    }
}
