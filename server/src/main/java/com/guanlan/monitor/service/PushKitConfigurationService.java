package com.guanlan.monitor.service;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.config.PushKitProperties;
import com.guanlan.monitor.domain.SystemSetting;
import com.guanlan.monitor.repository.SystemSettingRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.security.KeyFactory;
import java.security.MessageDigest;
import java.security.PrivateKey;
import java.security.spec.PKCS8EncodedKeySpec;
import java.time.Instant;
import java.util.Base64;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

@Service
@RequiredArgsConstructor(onConstructor_ = @Autowired)
public class PushKitConfigurationService {
    private static final String PREFIX = "notification.push_kit.";
    private static final String ENABLED = PREFIX + "enabled";
    private static final String PROJECT_ID = PREFIX + "project_id";
    private static final String KEY_ID = PREFIX + "key_id";
    private static final String SUB_ACCOUNT = PREFIX + "sub_account";
    private static final String PRIVATE_KEY = PREFIX + "private_key";
    private static final String CATEGORY = PREFIX + "category";
    private static final String TTL_SECONDS = PREFIX + "ttl_seconds";
    private static final String BATCH_SIZE = PREFIX + "batch_size";
    private static final String MAX_ATTEMPTS = PREFIX + "max_attempts";
    private static final Set<String> KEYS = Set.of(ENABLED, PROJECT_ID, KEY_ID, SUB_ACCOUNT, PRIVATE_KEY,
            CATEGORY, TTL_SECONDS, BATCH_SIZE, MAX_ATTEMPTS);

    private final SystemSettingRepository settings;
    private final PushKitProperties fallback;
    private final SecretValueCodec secrets;

    public PushKitConfigurationService(PushKitProperties fallback) {
        this.settings = null;
        this.fallback = fallback;
        this.secrets = null;
    }

    @Transactional(readOnly = true)
    public View get() {
        return view(runtime());
    }

    @Transactional(readOnly = true)
    public Runtime runtime() {
        if (settings == null) {
            return new Runtime(fallback.isEnabled(), value(fallback.getProjectId()), value(fallback.getKeyId()),
                    value(fallback.getSubAccount()), normalizePrivateKey(fallback.getPrivateKey()),
                    value(fallback.getCategory()).toUpperCase(Locale.ROOT), fallback.getTtlSeconds(),
                    fallback.getBatchSize(), fallback.getMaxAttempts(), "ENVIRONMENT");
        }
        Map<String, String> stored = new HashMap<>();
        settings.findAllById(KEYS).forEach(value -> stored.put(value.getKey(), value.getValue()));
        String privateKey = stored.containsKey(PRIVATE_KEY)
                ? secrets.decrypt(stored.get(PRIVATE_KEY)) : normalizePrivateKey(fallback.getPrivateKey());
        return new Runtime(
                booleanValue(stored, ENABLED, fallback.isEnabled()),
                stringValue(stored, PROJECT_ID, fallback.getProjectId()),
                stringValue(stored, KEY_ID, fallback.getKeyId()),
                stringValue(stored, SUB_ACCOUNT, fallback.getSubAccount()),
                privateKey,
                stringValue(stored, CATEGORY, fallback.getCategory()).toUpperCase(Locale.ROOT),
                intValue(stored, TTL_SECONDS, fallback.getTtlSeconds()),
                intValue(stored, BATCH_SIZE, fallback.getBatchSize()),
                intValue(stored, MAX_ATTEMPTS, fallback.getMaxAttempts()),
                stored.containsKey(PRIVATE_KEY) ? "DATABASE" : configured(privateKey) ? "ENVIRONMENT" : "NONE"
        );
    }

    @Transactional
    public View update(Update request) {
        validateUpdate(request);
        save(ENABLED, request.enabled());
        save(PROJECT_ID, request.projectId().trim());
        save(KEY_ID, request.keyId().trim());
        save(SUB_ACCOUNT, request.subAccount().trim());
        save(CATEGORY, request.category().trim().toUpperCase(Locale.ROOT));
        save(TTL_SECONDS, request.ttlSeconds());
        save(BATCH_SIZE, request.batchSize());
        save(MAX_ATTEMPTS, request.maxAttempts());
        updatePrivateKey(request.privateKey(), request.clearPrivateKey());

        Runtime current = runtime();
        if (current.enabled()) {
            try {
                assertValid(current);
            } catch (IllegalStateException exception) {
                throw new ApiException(HttpStatus.BAD_REQUEST, exception.getMessage());
            }
        }
        return view(current);
    }

    @Transactional(readOnly = true)
    public ValidationResult validate() {
        Runtime current = runtime();
        try {
            assertValid(current);
            return new ValidationResult("VALID", "Push Kit V3 服务账号与 PKCS#8 签名密钥校验通过", Instant.now());
        } catch (IllegalStateException exception) {
            throw new ApiException(HttpStatus.BAD_REQUEST, exception.getMessage());
        }
    }

    public void assertValid(Runtime runtime) {
        require("项目 ID", runtime.projectId());
        require("Key ID", runtime.keyId());
        require("子账号", runtime.subAccount());
        require("PKCS#8 私钥", runtime.privateKey());
        if (!runtime.projectId().matches("^[A-Za-z0-9_-]{1,128}$")) {
            throw new IllegalStateException("Push Kit 项目 ID 格式无效");
        }
        if (runtime.keyId().length() > 256 || runtime.subAccount().length() > 256) {
            throw new IllegalStateException("Push Kit 服务账号字段长度无效");
        }
        if (!runtime.category().matches("^[A-Z][A-Z0-9_]{0,63}$")) {
            throw new IllegalStateException("Push Kit 通知分类格式无效");
        }
        if (runtime.ttlSeconds() < 1 || runtime.ttlSeconds() > 1_296_000) {
            throw new IllegalStateException("Push Kit 消息缓存时间应为 1-1296000 秒");
        }
        if (runtime.batchSize() < 1 || runtime.batchSize() > 200) {
            throw new IllegalStateException("Push Kit 批处理数量应为 1-200");
        }
        if (runtime.maxAttempts() < 1 || runtime.maxAttempts() > 10) {
            throw new IllegalStateException("Push Kit 最大尝试次数应为 1-10");
        }
        privateKey(runtime.privateKey());
    }

    public PrivateKey privateKey(String value) {
        try {
            String encoded = normalizePrivateKey(value)
                    .replace("-----BEGIN PRIVATE KEY-----", "")
                    .replace("-----END PRIVATE KEY-----", "")
                    .replaceAll("\\s", "");
            return KeyFactory.getInstance("RSA").generatePrivate(
                    new PKCS8EncodedKeySpec(Base64.getDecoder().decode(encoded)));
        } catch (Exception exception) {
            throw new IllegalStateException("Push Kit 私钥必须是有效的 PKCS#8 RSA 私钥");
        }
    }

    public String fingerprint(Runtime runtime) {
        try {
            String material = runtime.projectId() + "\n" + runtime.keyId() + "\n" + runtime.subAccount()
                    + "\n" + runtime.privateKey();
            return Base64.getEncoder().encodeToString(
                    MessageDigest.getInstance("SHA-256").digest(material.getBytes(java.nio.charset.StandardCharsets.UTF_8)));
        } catch (Exception exception) {
            throw new IllegalStateException("SHA-256 unavailable", exception);
        }
    }

    private void validateUpdate(Update request) {
        if (request == null || request.projectId() == null || request.keyId() == null
                || request.subAccount() == null || request.category() == null) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "Push Kit 设置内容不完整");
        }
        if (request.projectId().length() > 128 || request.keyId().length() > 256
                || request.subAccount().length() > 256 || request.category().length() > 64) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "Push Kit 配置值长度无效");
        }
        if (request.privateKey() != null && request.privateKey().length() > 16_384) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "Push Kit 私钥内容过长");
        }
        if (request.clearPrivateKey() && configured(request.privateKey())) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "不能同时替换和清除 Push Kit 私钥");
        }
        if (configured(request.privateKey())) {
            try {
                privateKey(request.privateKey());
            } catch (IllegalStateException exception) {
                throw new ApiException(HttpStatus.BAD_REQUEST, exception.getMessage());
            }
        }
        if (request.ttlSeconds() < 1 || request.ttlSeconds() > 1_296_000
                || request.batchSize() < 1 || request.batchSize() > 200
                || request.maxAttempts() < 1 || request.maxAttempts() > 10) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "Push Kit 数值配置超出允许范围");
        }
    }

    private void updatePrivateKey(String replacement, boolean clear) {
        if (clear) {
            settings.deleteById(PRIVATE_KEY);
            return;
        }
        if (!configured(replacement)) return;
        if (secrets == null || !secrets.available()) {
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "未配置设置加密密钥，无法保存 Push Kit 私钥");
        }
        save(PRIVATE_KEY, secrets.encrypt(normalizePrivateKey(replacement)));
    }

    private View view(Runtime runtime) {
        boolean complete = configured(runtime.projectId()) && configured(runtime.keyId())
                && configured(runtime.subAccount()) && configured(runtime.privateKey());
        return new View(runtime.enabled(), complete, runtime.source(), runtime.projectId(), runtime.keyId(),
                runtime.subAccount(), configured(runtime.privateKey()), runtime.category(), runtime.ttlSeconds(),
                runtime.batchSize(), runtime.maxAttempts());
    }

    private String stringValue(Map<String, String> stored, String key, String defaultValue) {
        return stored.containsKey(key) ? stored.get(key).trim() : defaultValue == null ? "" : defaultValue.trim();
    }

    private boolean booleanValue(Map<String, String> stored, String key, boolean defaultValue) {
        return stored.containsKey(key) ? Boolean.parseBoolean(stored.get(key)) : defaultValue;
    }

    private int intValue(Map<String, String> stored, String key, int defaultValue) {
        if (!stored.containsKey(key)) return defaultValue;
        try {
            return Integer.parseInt(stored.get(key));
        } catch (NumberFormatException ignored) {
            return defaultValue;
        }
    }

    private void save(String key, String value) {
        settings.save(new SystemSetting(key, value == null ? "" : value));
    }

    private void save(String key, boolean value) {
        save(key, Boolean.toString(value));
    }

    private void save(String key, int value) {
        save(key, Integer.toString(value));
    }

    private void require(String label, String value) {
        if (!configured(value)) throw new IllegalStateException("启用 Push Kit 前请配置" + label);
    }

    private String normalizePrivateKey(String value) {
        return value == null ? "" : value.replace("\\n", "\n").trim();
    }

    private boolean configured(String value) {
        return value != null && !value.isBlank();
    }

    private String value(String value) {
        return value == null ? "" : value.trim();
    }

    public record View(boolean enabled, boolean configured, String source, String projectId, String keyId,
                       String subAccount, boolean privateKeyConfigured, String category, int ttlSeconds,
                       int batchSize, int maxAttempts) {}

    public record Update(boolean enabled, String projectId, String keyId, String subAccount, String privateKey,
                         boolean clearPrivateKey, String category, int ttlSeconds, int batchSize, int maxAttempts) {}

    public record Runtime(boolean enabled, String projectId, String keyId, String subAccount, String privateKey,
                          String category, int ttlSeconds, int batchSize, int maxAttempts, String source) {}

    public record ValidationResult(String status, String message, Instant checkedAt) {}
}
