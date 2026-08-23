package com.guanlan.monitor.service;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.api.dto.ApiTokenDtos;
import com.guanlan.monitor.domain.ApiToken;
import com.guanlan.monitor.domain.UserAccount;
import com.guanlan.monitor.repository.ApiTokenRepository;
import com.guanlan.monitor.repository.UserAccountRepository;
import com.guanlan.monitor.security.ApiTokenPrincipal;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.Base64;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Optional;
import java.util.Set;

@Service
@RequiredArgsConstructor
public class ApiTokenService {
    private static final TypeReference<List<String>> STRING_LIST = new TypeReference<>() {};
    private final ApiTokenRepository tokens;
    private final UserAccountRepository users;
    private final ObjectMapper mapper;
    private final AuditService audit;
    private final SecureRandom random = new SecureRandom();

    @Transactional
    public ApiTokenDtos.Created create(String username, ApiTokenDtos.CreateRequest request) {
        UserAccount user = user(username);
        List<String> scopes = normalize(request.scopes(), 32, "权限范围不能为空");
        List<String> serverIds = normalize(request.serverIds(), 1000, "服务器白名单无效");
        validateScopes(user, scopes);
        Instant expiresAt = null;
        if (request.expiresInDays() != null && request.expiresInDays() > 0) {
            expiresAt = Instant.now().plus(request.expiresInDays(), ChronoUnit.DAYS);
        }

        String secret = newSecret();
        ApiToken token = new ApiToken();
        token.setUser(user);
        token.setName(request.name().trim());
        token.setTokenHash(hash(secret));
        token.setTokenPrefix(secret.substring(0, Math.min(16, secret.length())));
        token.setScopesJson(json(scopes));
        token.setServerIdsJson(json(serverIds));
        token.setExpiresAt(expiresAt);
        tokens.save(token);
        audit.record("API_TOKEN_CREATE", "api-token:" + token.getId(), "创建 API Token " + token.getName());
        return new ApiTokenDtos.Created(view(token), secret);
    }

    @Transactional(readOnly = true)
    public List<ApiTokenDtos.View> list(String username) {
        UserAccount user = user(username);
        return tokens.findAllByUserIdOrderByCreatedAtDesc(user.getId()).stream().map(this::view).toList();
    }

    @Transactional
    public void revoke(String username, Long id) {
        UserAccount user = user(username);
        ApiToken token = tokens.findByIdAndUserId(id, user.getId())
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "API Token 不存在"));
        if (token.getRevokedAt() == null) {
            token.setRevokedAt(Instant.now());
            audit.record("API_TOKEN_REVOKE", "api-token:" + id, "吊销 API Token " + token.getName());
        }
    }

    @Transactional
    public Optional<ApiTokenPrincipal> authenticate(String secret, String ip) {
        if (secret == null || secret.isBlank()) return Optional.empty();
        ApiToken token = tokens.findByTokenHashAndRevokedAtIsNull(hash(secret)).orElse(null);
        if (token == null || (token.getExpiresAt() != null && !token.getExpiresAt().isAfter(Instant.now()))) {
            return Optional.empty();
        }
        UserAccount user = token.getUser();
        if (!user.isEnabled()) return Optional.empty();
        token.setLastUsedAt(Instant.now());
        token.setLastUsedIp(ip == null ? "" : ip.substring(0, Math.min(64, ip.length())));
        return Optional.of(new ApiTokenPrincipal(token.getId(), user.getUsername(), user.getRole().name(), Set.copyOf(parse(token.getScopesJson())), Set.copyOf(parse(token.getServerIdsJson()))));
    }

    private UserAccount user(String username) {
        return users.findByUsernameIgnoreCase(username)
                .orElseThrow(() -> new ApiException(HttpStatus.UNAUTHORIZED, "会话已失效"));
    }

    private void validateScopes(UserAccount user, List<String> scopes) {
        for (String scope : scopes) {
            if (!scope.matches("^nezha:[a-z][a-z0-9-]*:(read|write|delete|exec|\\*)$") && !scope.equals("nezha:*")) {
                throw new ApiException(HttpStatus.BAD_REQUEST, "权限范围格式无效");
            }
            if (user.getRole() != UserAccount.Role.ADMIN && (scope.startsWith("nezha:admin:") || scope.equals("nezha:*"))) {
                throw new ApiException(HttpStatus.FORBIDDEN, "只有管理员可以签发管理员权限范围");
            }
        }
    }

    private List<String> normalize(List<String> values, int max, String message) {
        if (values == null) return List.of();
        LinkedHashSet<String> unique = new LinkedHashSet<>();
        for (String value : values) {
            if (value == null || value.isBlank()) throw new ApiException(HttpStatus.BAD_REQUEST, message);
            unique.add(value.trim());
        }
        if (unique.size() > max) throw new ApiException(HttpStatus.BAD_REQUEST, message);
        return List.copyOf(unique);
    }

    private ApiTokenDtos.View view(ApiToken token) {
        return new ApiTokenDtos.View(token.getId(), token.getName(), token.getTokenPrefix(), parse(token.getScopesJson()), parse(token.getServerIdsJson()), token.getExpiresAt(), token.getLastUsedAt(), token.getLastUsedIp(), token.getRevokedAt(), token.getCreatedAt());
    }

    private List<String> parse(String value) {
        if (value == null || value.isBlank()) return List.of();
        try { return mapper.readValue(value, STRING_LIST); }
        catch (Exception ignored) { return List.of(); }
    }

    private String json(List<String> value) {
        try { return mapper.writeValueAsString(value); }
        catch (Exception exception) { throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "API Token 权限保存失败"); }
    }

    private String newSecret() {
        byte[] bytes = new byte[32];
        random.nextBytes(bytes);
        return "nzp_" + Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    private String hash(String secret) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(secret.getBytes(StandardCharsets.UTF_8));
            StringBuilder value = new StringBuilder(64);
            for (byte item : digest) value.append(String.format("%02x", item));
            return value.toString();
        } catch (Exception exception) {
            throw new IllegalStateException("SHA-256 unavailable", exception);
        }
    }
}
