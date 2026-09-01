package com.guanlan.monitor.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.api.dto.MobileInstallationDtos;
import com.guanlan.monitor.domain.MobileInstallation;
import com.guanlan.monitor.domain.MobilePushDelivery;
import com.guanlan.monitor.domain.ApiToken;
import com.guanlan.monitor.domain.UserAccount;
import com.guanlan.monitor.repository.ApiTokenRepository;
import com.guanlan.monitor.repository.MobileInstallationRepository;
import com.guanlan.monitor.repository.MobilePushDeliveryRepository;
import com.guanlan.monitor.repository.UserAccountRepository;
import com.guanlan.monitor.security.ApiTokenPrincipal;
import com.guanlan.monitor.push.PushKitClient;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.Authentication;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.Collection;
import java.util.HexFormat;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

@Service
@RequiredArgsConstructor
public class MobileInstallationService {
    private final MobileInstallationRepository installations;
    private final UserAccountRepository users;
    private final ApiTokenRepository apiTokens;
    private final MobilePushDeliveryRepository deliveries;
    private final DeviceAccessService access;
    private final SecretValueCodec secrets;
    private final PushKitClient pushKit;
    private final ObjectMapper mapper;

    @Transactional
    public MobileInstallationDtos.View create(Authentication authentication, MobileInstallationDtos.CreateRequest request) {
        ApiToken token = requireToken(authentication);
        UserAccount user = token.getUser();
        String clientId = request.clientInstallationId().trim();
        MobileInstallation installation = installations.findByApiTokenIdAndClientInstallationId(token.getId(), clientId)
                .orElseGet(MobileInstallation::new);
        installation.setUser(user);
        installation.setApiToken(token);
        installation.setClientInstallationId(clientId);
        installation.setPlatform(request.platform());
        installation.setAppVersion(normalize(request.appVersion()));
        installation.setDeviceModel(normalize(request.deviceModel()));
        installation.setDeviceIdsJson(json(validateDeviceIds(authentication, request.deviceIds())));
        installation.setMinimumSeverity(request.minimumSeverity() == null
                ? com.guanlan.monitor.domain.AlertRule.Severity.WARNING : request.minimumSeverity());
        installation.setEnabled(true);
        if (request.token() != null && !request.token().isBlank()) {
            requireEncryption();
            updateToken(installation, request.token());
        }
        installations.save(installation);
        return view(installation);
    }

    @Transactional(readOnly = true)
    public List<MobileInstallationDtos.View> list(Authentication authentication) {
        ApiToken token = requireToken(authentication);
        return installations.findByApiTokenIdOrderByUpdatedAtDesc(token.getId()).stream()
                .map(this::view).toList();
    }

    @Transactional
    public MobileInstallationDtos.View updateToken(Authentication authentication, String id,
                                                    MobileInstallationDtos.TokenUpdateRequest request) {
        requireEncryption();
        requireToken(authentication);
        MobileInstallation installation = requireOwned(authentication, id);
        updateToken(installation, request.token());
        if (request.appVersion() != null) installation.setAppVersion(normalize(request.appVersion()));
        installation.setEnabled(true);
        return view(installation);
    }

    @Transactional
    public MobileInstallationDtos.View updatePreferences(Authentication authentication, String id,
                                                          MobileInstallationDtos.PreferencesRequest request) {
        if (request == null || request.enabled() == null && request.deviceIds() == null
                && request.minimumSeverity() == null) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "至少需要更新一项推送偏好");
        }
        MobileInstallation installation = requireOwned(authentication, id);
        if (request.enabled() != null) installation.setEnabled(request.enabled());
        if (request.deviceIds() != null) {
            installation.setDeviceIdsJson(json(validateDeviceIds(authentication, request.deviceIds())));
        }
        if (request.minimumSeverity() != null) installation.setMinimumSeverity(request.minimumSeverity());
        return view(installation);
    }

    @Transactional
    public void delete(Authentication authentication, String id) {
        installations.delete(requireOwned(authentication, id));
    }

    @Transactional
    public MobileInstallationDtos.TestResult test(Authentication authentication, String id) {
        MobileInstallation installation = requireOwned(authentication, id);
        if (!pushKit.enabled()) throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "华为 Push Kit 尚未启用");
        if (!installation.isEnabled()) throw new ApiException(HttpStatus.CONFLICT, "该移动设备已停用推送");
        if (installation.getTokenCiphertext() == null || installation.getTokenCiphertext().isBlank()) {
            throw new ApiException(HttpStatus.CONFLICT, "该移动设备尚未登记 Push token");
        }
        if (installation.getLastTestAt() != null && installation.getLastTestAt().isAfter(Instant.now().minusSeconds(60))) {
            throw new ApiException(HttpStatus.TOO_MANY_REQUESTS, "测试推送请求过于频繁");
        }
        requireEncryption();
        try {
            String eventId = "test:" + UUID.randomUUID();
            MobilePushDelivery delivery = new MobilePushDelivery();
            delivery.setOutboxEventId(eventId);
            delivery.setInstallation(installation);
            delivery.setEventType("push.test");
            delivery.setTitle("星辰监控");
            delivery.setBody("移动推送测试成功");
            delivery.setDataJson(mapper.writeValueAsString(Map.of(
                    "controllerId", "",
                    "eventType", "push.test",
                    "installationId", installation.getId())));
            installation.setLastTestAt(Instant.now());
            MobilePushDelivery saved = deliveries.saveAndFlush(delivery);
            return new MobileInstallationDtos.TestResult("QUEUED", saved.getId(), "测试推送已提交");
        } catch (Exception exception) {
            if (exception instanceof ApiException apiException) throw apiException;
            throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "移动推送测试入队失败");
        }
    }

    private void updateToken(MobileInstallation installation, String tokenValue) {
        if (tokenValue == null || tokenValue.isBlank()) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "Push token 不能为空");
        }
        String token = tokenValue.trim();
        String fingerprint = fingerprint(token);
        String id = installation.getId() == null ? "" : installation.getId();
        if (installations.existsByTokenFingerprintAndIdNot(fingerprint, id)) {
            throw new ApiException(HttpStatus.CONFLICT, "该推送令牌已由其他移动设备登记");
        }
        installation.setTokenCiphertext(secrets.encrypt(token));
        installation.setTokenFingerprint(fingerprint);
        installation.setTokenSuffix(token.substring(Math.max(0, token.length() - 8)));
        installation.setLastRegisteredAt(Instant.now());
    }

    private MobileInstallation requireOwned(Authentication authentication, String id) {
        ApiToken token = requireToken(authentication);
        return installations.findByIdAndApiTokenId(id, token.getId())
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "移动设备登记不存在"));
    }

    private ApiToken requireToken(Authentication authentication) {
        if (authentication == null || !(authentication.getPrincipal() instanceof ApiTokenPrincipal principal)
                || principal.tokenId() == null) {
            throw new ApiException(HttpStatus.FORBIDDEN, "移动推送接口需要 API Token");
        }
        ApiToken token = apiTokens.findByIdAndUserIdAndRevokedAtIsNull(principal.tokenId(), userId(authentication))
                .orElseThrow(() -> new ApiException(HttpStatus.UNAUTHORIZED, "API Token 无效或已过期"));
        if (token.getExpiresAt() != null && !token.getExpiresAt().isAfter(Instant.now())
                || !token.getUser().isEnabled()) {
            throw new ApiException(HttpStatus.UNAUTHORIZED, "API Token 无效或已过期");
        }
        return token;
    }

    private Long userId(Authentication authentication) {
        return users.findByUsernameIgnoreCase(authentication.getName())
                .map(UserAccount::getId)
                .orElseThrow(() -> new ApiException(HttpStatus.UNAUTHORIZED, "会话已失效"));
    }

    private void requireEncryption() {
        if (!secrets.available()) throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "服务端未配置敏感信息加密密钥");
    }

    private String fingerprint(String value) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(value.getBytes(StandardCharsets.UTF_8)));
        } catch (Exception exception) {
            throw new IllegalStateException("SHA-256 unavailable", exception);
        }
    }

    private String normalize(String value) {
        return value == null || value.isBlank() ? null : value.trim();
    }

    private List<String> validateDeviceIds(Authentication authentication, List<String> values) {
        if (values == null || values.isEmpty()) return List.of();
        LinkedHashSet<String> normalized = new LinkedHashSet<>();
        for (String value : values) {
            if (value == null || value.isBlank() || !normalized.add(value.trim())) {
                throw new ApiException(HttpStatus.BAD_REQUEST, "设备范围包含空值或重复设备");
            }
            if (!access.canView(authentication, value.trim())) {
                throw new ApiException(HttpStatus.FORBIDDEN, "设备范围超出当前 API Token 权限");
            }
        }
        if (normalized.size() > 500) throw new ApiException(HttpStatus.BAD_REQUEST, "设备范围过大");
        return List.copyOf(normalized);
    }

    private String json(Collection<String> values) {
        try {
            return mapper.writeValueAsString(values.stream().sorted().toList());
        } catch (Exception exception) {
            throw new IllegalStateException("Unable to serialize mobile installation scope", exception);
        }
    }

    private List<String> parseDeviceIds(String value) {
        if (value == null || value.isBlank()) return List.of();
        try {
            return mapper.readValue(value, new com.fasterxml.jackson.core.type.TypeReference<List<String>>() {});
        } catch (Exception exception) {
            return List.of();
        }
    }

    private MobileInstallationDtos.View view(MobileInstallation value) {
        return new MobileInstallationDtos.View(value.getId(), value.getClientInstallationId(), value.getPlatform(),
                value.getTokenSuffix(), value.getAppVersion(), value.getDeviceModel(), parseDeviceIds(value.getDeviceIdsJson()),
                value.getMinimumSeverity(), value.isEnabled(), value.getLastRegisteredAt(),
                value.getCreatedAt(), value.getUpdatedAt());
    }
}
