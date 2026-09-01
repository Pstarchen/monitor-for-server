package com.guanlan.monitor.push;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.service.PushKitConfigurationService;
import com.guanlan.monitor.config.PushKitProperties;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.PrivateKey;
import java.security.Signature;
import java.security.spec.MGF1ParameterSpec;
import java.security.spec.PSSParameterSpec;
import java.time.Instant;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Map;

@Component
@RequiredArgsConstructor(onConstructor_ = @Autowired)
public class PushKitServiceAccount {
    static final String AUDIENCE = "https://oauth-login.cloud.huawei.com/oauth2/v3/token";
    private static final String SEND_URL_PREFIX = "https://push-api.cloud.huawei.com/v3/";
    private static final String SEND_URL_SUFFIX = "/messages:send";
    private final PushKitConfigurationService configurations;
    private final ObjectMapper mapper;
    private volatile CachedJwt cachedJwt;

    public PushKitServiceAccount(PushKitProperties properties, ObjectMapper mapper) {
        this(new PushKitConfigurationService(properties), mapper);
    }

    public void validate(PushKitConfigurationService.Runtime runtime) {
        configurations.assertValid(runtime);
    }

    public void validate() {
        validate(configurations.runtime());
    }

    public URI sendUri(PushKitConfigurationService.Runtime runtime) {
        return URI.create(SEND_URL_PREFIX + runtime.projectId() + SEND_URL_SUFFIX);
    }

    public URI sendUri() {
        return sendUri(configurations.runtime());
    }

    public String jwt(PushKitConfigurationService.Runtime runtime) {
        Instant now = Instant.now();
        String fingerprint = configurations.fingerprint(runtime);
        CachedJwt current = cachedJwt;
        if (current != null && current.fingerprint().equals(fingerprint)
                && current.expiresAt().isAfter(now.plusSeconds(30))) return current.value();
        synchronized (this) {
            current = cachedJwt;
            if (current != null && current.fingerprint().equals(fingerprint)
                    && current.expiresAt().isAfter(Instant.now().plusSeconds(30))) return current.value();
            Instant issuedAt = Instant.now();
            Instant expiresAt = issuedAt.plusSeconds(3600);
            String value = sign(runtime, issuedAt, expiresAt);
            cachedJwt = new CachedJwt(value, expiresAt, fingerprint);
            return value;
        }
    }

    public String jwt() {
        return jwt(configurations.runtime());
    }

    public void invalidateJwt() {
        cachedJwt = null;
    }

    private String sign(PushKitConfigurationService.Runtime runtime, Instant issuedAt, Instant expiresAt) {
        try {
            Map<String, Object> header = new LinkedHashMap<>();
            header.put("kid", runtime.keyId());
            header.put("typ", "JWT");
            header.put("alg", "PS256");
            Map<String, Object> payload = new LinkedHashMap<>();
            payload.put("aud", AUDIENCE);
            payload.put("iss", runtime.subAccount());
            payload.put("exp", expiresAt.getEpochSecond());
            payload.put("iat", issuedAt.getEpochSecond());
            String signingInput = encode(mapper.writeValueAsBytes(header)) + "." + encode(mapper.writeValueAsBytes(payload));
            Signature signature = Signature.getInstance("RSASSA-PSS");
            PrivateKey privateKey = configurations.privateKey(runtime.privateKey());
            signature.initSign(privateKey);
            signature.setParameter(new PSSParameterSpec("SHA-256", "MGF1",
                    MGF1ParameterSpec.SHA256, 32, 1));
            signature.update(signingInput.getBytes(StandardCharsets.US_ASCII));
            return signingInput + "." + encode(signature.sign());
        } catch (Exception exception) {
            throw new IllegalStateException("Unable to generate Huawei Push Kit service account JWT", exception);
        }
    }

    private String encode(byte[] value) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(value);
    }

    private record CachedJwt(String value, Instant expiresAt, String fingerprint) {}
}
