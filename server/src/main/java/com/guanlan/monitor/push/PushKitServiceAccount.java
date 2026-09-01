package com.guanlan.monitor.push;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.config.PushKitProperties;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.PrivateKey;
import java.security.Signature;
import java.security.spec.MGF1ParameterSpec;
import java.security.spec.PKCS8EncodedKeySpec;
import java.security.spec.PSSParameterSpec;
import java.time.Instant;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Map;

@Component
@RequiredArgsConstructor
public class PushKitServiceAccount {
    static final String AUDIENCE = "https://oauth-login.cloud.huawei.com/oauth2/v3/token";
    private static final String SEND_URL_PREFIX = "https://push-api.cloud.huawei.com/v3/";
    private static final String SEND_URL_SUFFIX = "/messages:send";
    private final PushKitProperties properties;
    private final ObjectMapper mapper;
    private volatile PrivateKey privateKey;
    private volatile CachedJwt cachedJwt;

    public void validate() {
        require("PUSH_KIT_PROJECT_ID", properties.getProjectId());
        require("PUSH_KIT_KEY_ID", properties.getKeyId());
        require("PUSH_KIT_SUB_ACCOUNT", properties.getSubAccount());
        require("PUSH_KIT_PRIVATE_KEY", properties.getPrivateKey());
        if (!properties.getProjectId().trim().matches("^[A-Za-z0-9_-]{1,128}$")) {
            throw new IllegalStateException("PUSH_KIT_PROJECT_ID has an invalid format");
        }
        if (properties.getCategory() == null
                || !properties.getCategory().trim().matches("^[A-Z][A-Z0-9_]{1,63}$")) {
            throw new IllegalStateException("PUSH_KIT_CATEGORY has an invalid format");
        }
        if (properties.getTtlSeconds() < 1) {
            throw new IllegalStateException("PUSH_KIT_TTL_SECONDS must be positive");
        }
        privateKey();
    }

    public URI sendUri() {
        return URI.create(SEND_URL_PREFIX + properties.getProjectId().trim() + SEND_URL_SUFFIX);
    }

    public String jwt() {
        Instant now = Instant.now();
        CachedJwt current = cachedJwt;
        if (current != null && current.expiresAt().isAfter(now.plusSeconds(30))) return current.value();
        synchronized (this) {
            current = cachedJwt;
            if (current != null && current.expiresAt().isAfter(Instant.now().plusSeconds(30))) return current.value();
            Instant issuedAt = Instant.now();
            Instant expiresAt = issuedAt.plusSeconds(3600);
            String value = sign(issuedAt, expiresAt);
            cachedJwt = new CachedJwt(value, expiresAt);
            return value;
        }
    }

    public void invalidateJwt() {
        cachedJwt = null;
    }

    private String sign(Instant issuedAt, Instant expiresAt) {
        try {
            Map<String, Object> header = new LinkedHashMap<>();
            header.put("kid", properties.getKeyId().trim());
            header.put("typ", "JWT");
            header.put("alg", "PS256");
            Map<String, Object> payload = new LinkedHashMap<>();
            payload.put("aud", AUDIENCE);
            payload.put("iss", properties.getSubAccount().trim());
            payload.put("exp", expiresAt.getEpochSecond());
            payload.put("iat", issuedAt.getEpochSecond());
            String signingInput = encode(mapper.writeValueAsBytes(header)) + "." + encode(mapper.writeValueAsBytes(payload));
            Signature signature = Signature.getInstance("RSASSA-PSS");
            signature.initSign(privateKey());
            signature.setParameter(new PSSParameterSpec("SHA-256", "MGF1",
                    MGF1ParameterSpec.SHA256, 32, 1));
            signature.update(signingInput.getBytes(StandardCharsets.US_ASCII));
            return signingInput + "." + encode(signature.sign());
        } catch (Exception exception) {
            throw new IllegalStateException("Unable to generate Huawei Push Kit service account JWT", exception);
        }
    }

    private PrivateKey privateKey() {
        PrivateKey current = privateKey;
        if (current != null) return current;
        synchronized (this) {
            if (privateKey != null) return privateKey;
            try {
                String value = properties.getPrivateKey().replace("\\n", "\n").trim()
                        .replace("-----BEGIN PRIVATE KEY-----", "")
                        .replace("-----END PRIVATE KEY-----", "")
                        .replaceAll("\\s", "");
                byte[] encoded = Base64.getDecoder().decode(value);
                privateKey = KeyFactory.getInstance("RSA").generatePrivate(new PKCS8EncodedKeySpec(encoded));
                return privateKey;
            } catch (Exception exception) {
                throw new IllegalStateException("PUSH_KIT_PRIVATE_KEY must be a valid PKCS#8 RSA private key");
            }
        }
    }

    private String encode(byte[] value) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(value);
    }

    private void require(String name, String value) {
        if (value == null || value.isBlank()) {
            throw new IllegalStateException(name + " is required when PUSH_KIT_ENABLED=true");
        }
    }

    private record CachedJwt(String value, Instant expiresAt) {}
}
