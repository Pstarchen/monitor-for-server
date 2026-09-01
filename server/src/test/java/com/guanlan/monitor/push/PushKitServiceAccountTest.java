package com.guanlan.monitor.push;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.config.PushKitProperties;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.Signature;
import java.security.spec.MGF1ParameterSpec;
import java.security.spec.PSSParameterSpec;
import java.util.Base64;

import static org.assertj.core.api.Assertions.assertThat;

class PushKitServiceAccountTest {
    @Test
    void createsOfficialPs256ServiceAccountJwtAndV3SendUri() throws Exception {
        ObjectMapper mapper = new ObjectMapper();
        KeyPair keyPair = rsaKeyPair();
        PushKitProperties properties = properties(keyPair);
        PushKitServiceAccount account = new PushKitServiceAccount(properties, mapper);

        String jwt = account.jwt();
        String[] parts = jwt.split("\\.");
        JsonNode header = decode(mapper, parts[0]);
        JsonNode payload = decode(mapper, parts[1]);

        assertThat(parts).hasSize(3);
        assertThat(header.path("alg").asText()).isEqualTo("PS256");
        assertThat(header.path("typ").asText()).isEqualTo("JWT");
        assertThat(header.path("kid").asText()).isEqualTo("test-key-id");
        assertThat(payload.path("aud").asText()).isEqualTo(PushKitServiceAccount.AUDIENCE);
        assertThat(payload.path("iss").asText()).isEqualTo("test-sub-account");
        assertThat(payload.path("exp").asLong() - payload.path("iat").asLong()).isEqualTo(3600);
        assertThat(account.sendUri()).hasToString(
                "https://push-api.cloud.huawei.com/v3/123456789/messages:send");

        Signature verifier = Signature.getInstance("RSASSA-PSS");
        verifier.initVerify(keyPair.getPublic());
        verifier.setParameter(new PSSParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA256, 32, 1));
        verifier.update((parts[0] + "." + parts[1]).getBytes(StandardCharsets.US_ASCII));
        assertThat(verifier.verify(Base64.getUrlDecoder().decode(parts[2]))).isTrue();
    }

    static PushKitProperties properties(KeyPair keyPair) {
        PushKitProperties properties = new PushKitProperties();
        properties.setEnabled(true);
        properties.setProjectId("123456789");
        properties.setKeyId("test-key-id");
        properties.setSubAccount("test-sub-account");
        properties.setPrivateKey(pem(keyPair));
        return properties;
    }

    static KeyPair rsaKeyPair() throws Exception {
        KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
        generator.initialize(2048);
        return generator.generateKeyPair();
    }

    private static JsonNode decode(ObjectMapper mapper, String value) throws Exception {
        return mapper.readTree(Base64.getUrlDecoder().decode(value));
    }

    private static String pem(KeyPair keyPair) {
        String encoded = Base64.getMimeEncoder(64, new byte[]{'\n'})
                .encodeToString(keyPair.getPrivate().getEncoded());
        return "-----BEGIN PRIVATE KEY-----\n" + encoded + "\n-----END PRIVATE KEY-----";
    }
}
