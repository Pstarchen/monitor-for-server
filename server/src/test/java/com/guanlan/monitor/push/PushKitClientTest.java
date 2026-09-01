package com.guanlan.monitor.push;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.config.PushKitProperties;
import org.junit.jupiter.api.Test;
import org.springframework.web.client.RestClient;

import java.security.KeyPair;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class PushKitClientTest {
    @Test
    void buildsHarmonyOsNextPushKitV3AlertRequest() throws Exception {
        ObjectMapper mapper = new ObjectMapper();
        KeyPair keyPair = PushKitServiceAccountTest.rsaKeyPair();
        PushKitProperties properties = PushKitServiceAccountTest.properties(keyPair);
        PushKitServiceAccount account = new PushKitServiceAccount(properties, mapper);
        PushKitClient client = new PushKitClient(properties, account, RestClient.builder(), mapper);

        Map<String, Object> request = client.requestBody("harmony-token", "监控告警", "设备已离线",
                "{\"deviceId\":\"device-1\"}", true);
        JsonNode json = mapper.valueToTree(request);

        assertThat(json.path("payload").path("notification").path("category").asText()).isEqualTo("MARKETING");
        assertThat(json.path("payload").path("notification").path("clickAction").path("actionType").asInt())
                .isZero();
        assertThat(json.path("payload").path("notification").path("clickAction").path("data")
                .path("deviceId").asText()).isEqualTo("device-1");
        assertThat(json.path("target").path("token").get(0).asText()).isEqualTo("harmony-token");
        assertThat(json.path("pushOptions").path("testMessage").asBoolean()).isTrue();
        assertThat(json.path("pushOptions").path("ttl").asInt()).isEqualTo(86400);
        assertThat(json.has("message")).isFalse();
    }
}
