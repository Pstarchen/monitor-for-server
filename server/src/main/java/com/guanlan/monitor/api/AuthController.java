package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.UserDtos;
import com.guanlan.monitor.domain.UserAccount;
import com.guanlan.monitor.repository.UserAccountRepository;
import com.guanlan.monitor.security.LoginRateLimiter;
import com.guanlan.monitor.config.AppProperties;
import com.guanlan.monitor.service.AuditService;
import com.guanlan.monitor.service.SecretValueCodec;
import com.guanlan.monitor.service.TotpService;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.HttpSession;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.security.authentication.AuthenticationManager;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.userdetails.UserDetails;
import org.springframework.security.core.userdetails.UserDetailsService;
import org.springframework.security.core.context.SecurityContext;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.web.context.HttpSessionSecurityContextRepository;
import org.springframework.security.web.csrf.CsrfToken;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.*;
import com.guanlan.monitor.service.UserService;

import java.time.Duration;
import java.time.Instant;
import java.util.Map;

@RestController
@RequestMapping("/api/auth")
@RequiredArgsConstructor
public class AuthController {
    private static final String PENDING_USERNAME = "xingchen.2fa.pending.username";
    private static final String PENDING_RETURN_TO = "xingchen.2fa.pending.returnTo";
    private static final String PENDING_EXPIRES_AT = "xingchen.2fa.pending.expiresAt";
    private static final String SETUP_SECRET = "xingchen.2fa.setup.secret";
    private static final String SETUP_EXPIRES_AT = "xingchen.2fa.setup.expiresAt";
    private static final Duration PENDING_TTL = Duration.ofMinutes(5);
    private static final Duration SETUP_TTL = Duration.ofMinutes(10);

    private final AuthenticationManager authenticationManager;
    private final LoginRateLimiter rateLimiter;
    private final UserAccountRepository users;
    private final UserService userService;
    private final UserDetailsService userDetailsService;
    private final PasswordEncoder passwordEncoder;
    private final SecretValueCodec secrets;
    private final TotpService totp;
    private final AuditService audit;
    private final AppProperties properties;

    @GetMapping("/csrf")
    Map<String, String> csrf(CsrfToken token) {
        return Map.of("headerName", token.getHeaderName(), "token", token.getToken());
    }

    @PostMapping("/login")
    LoginResponse login(@Valid @RequestBody LoginRequest body, HttpServletRequest request, HttpServletResponse response) {
        String key = request.getRemoteAddr() + ":" + body.username().toLowerCase();
        if (!rateLimiter.allowed(key)) {
            throw new ApiException(HttpStatus.TOO_MANY_REQUESTS, "登录尝试过多，请稍后再试");
        }
        try {
            Authentication authentication = authenticationManager.authenticate(
                    UsernamePasswordAuthenticationToken.unauthenticated(body.username(), body.password()));
            rateLimiter.succeeded(key);
            UserAccount account = users.findByUsernameIgnoreCase(authentication.getName())
                    .orElseThrow(() -> new ApiException(HttpStatus.UNAUTHORIZED, "会话已失效"));
            if (account.isTotpEnabled()) {
                clearAuthentication(request, response);
                HttpSession session = request.getSession(true);
                request.changeSessionId();
                session = request.getSession(false);
                session.setAttribute(PENDING_USERNAME, account.getUsername());
                session.setAttribute(PENDING_RETURN_TO, safeReturn(body.returnTo()));
                session.setAttribute(PENDING_EXPIRES_AT, Instant.now().plus(PENDING_TTL).toEpochMilli());
                return new LoginResponse(null, safeReturn(body.returnTo()), true);
            }
            establishAuthentication(authentication, request, response);
            return new LoginResponse(current(authentication), safeReturn(body.returnTo()), false);
        } catch (org.springframework.security.core.AuthenticationException exception) {
            rateLimiter.failed(key);
            throw exception;
        }
    }

    @PostMapping("/2fa/verify")
    LoginResponse verifyTwoFactor(@Valid @RequestBody TwoFactorVerifyRequest body,
                                  HttpServletRequest request, HttpServletResponse response) {
        HttpSession session = request.getSession(false);
        String username = session == null ? null : (String) session.getAttribute(PENDING_USERNAME);
        Long expiresAt = session == null ? null : (Long) session.getAttribute(PENDING_EXPIRES_AT);
        if (username == null || expiresAt == null || expiresAt < System.currentTimeMillis()) {
            clearPending(session);
            throw new ApiException(HttpStatus.UNAUTHORIZED, "登录验证已过期，请重新输入密码");
        }
        String key = "2fa:" + request.getRemoteAddr() + ":" + username.toLowerCase();
        if (!rateLimiter.allowed(key)) {
            throw new ApiException(HttpStatus.TOO_MANY_REQUESTS, "验证码尝试过多，请稍后再试");
        }
        UserAccount account = users.findByUsernameIgnoreCase(username)
                .filter(UserAccount::isTotpEnabled)
                .filter(UserAccount::isEnabled)
                .orElseThrow(() -> new ApiException(HttpStatus.UNAUTHORIZED, "登录验证已失效，请重新登录"));
        String secret = decryptSecret(account);
        if (!totp.verify(secret, body.code(), Instant.now())) {
            rateLimiter.failed(key);
            throw new ApiException(HttpStatus.UNAUTHORIZED, "验证码错误或已过期");
        }
        rateLimiter.succeeded(key);
        UserDetails details = userDetailsService.loadUserByUsername(account.getUsername());
        Authentication authentication = UsernamePasswordAuthenticationToken.authenticated(
                details, null, details.getAuthorities());
        String returnTo = session.getAttribute(PENDING_RETURN_TO) instanceof String value ? value : "/dashboard";
        clearPending(session);
        establishAuthentication(authentication, request, response);
        return new LoginResponse(current(authentication), safeReturn(returnTo), false);
    }

    @GetMapping("/2fa/status")
    TwoFactorStatus twoFactorStatus(Authentication authentication) {
        return new TwoFactorStatus(account(authentication).isTotpEnabled());
    }

    @PostMapping("/2fa/setup")
    TwoFactorSetup setupTwoFactor(@Valid @RequestBody CurrentPasswordRequest body,
                                  Authentication authentication, HttpServletRequest request) {
        UserAccount account = account(authentication);
        if (account.isTotpEnabled()) throw new ApiException(HttpStatus.CONFLICT, "双因素认证已启用");
        if (!passwordEncoder.matches(body.currentPassword(), account.getPasswordHash())) {
            throw new ApiException(HttpStatus.UNAUTHORIZED, "当前密码不正确");
        }
        if (!secrets.available()) {
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "未配置设置加密密钥，无法启用双因素认证");
        }
        String secret = totp.generateSecret();
        HttpSession session = request.getSession(true);
        session.setAttribute(SETUP_SECRET, secret);
        session.setAttribute(SETUP_EXPIRES_AT, Instant.now().plus(SETUP_TTL).toEpochMilli());
        return new TwoFactorSetup(secret, totp.otpauthUri(secret, properties.getSiteName(), account.getUsername()),
                Instant.ofEpochMilli((Long) session.getAttribute(SETUP_EXPIRES_AT)));
    }

    @PostMapping("/2fa/enable")
    @Transactional
    TwoFactorStatus enableTwoFactor(@Valid @RequestBody CodeRequest body,
                                    Authentication authentication, HttpServletRequest request) {
        UserAccount account = account(authentication);
        String secret = setupSecret(request.getSession(false));
        String attemptKey = twoFactorActionKey(request, account);
        if (!rateLimiter.allowed(attemptKey)) {
            throw new ApiException(HttpStatus.TOO_MANY_REQUESTS, "验证码尝试过多，请稍后再试");
        }
        if (!totp.verify(secret, body.code(), Instant.now())) {
            rateLimiter.failed(attemptKey);
            throw new ApiException(HttpStatus.UNAUTHORIZED, "验证码错误或已过期");
        }
        rateLimiter.succeeded(attemptKey);
        account.setTotpSecretCiphertext(secrets.encrypt(secret));
        account.setTotpEnabled(true);
        users.save(account);
        clearSetup(request.getSession(false));
        audit.record("USER_2FA_ENABLE", "user:" + account.getId(), "启用双因素认证");
        return new TwoFactorStatus(true);
    }

    @PostMapping("/2fa/disable")
    @Transactional
    TwoFactorStatus disableTwoFactor(@Valid @RequestBody DisableTwoFactorRequest body,
                                     Authentication authentication, HttpServletRequest request) {
        UserAccount account = account(authentication);
        if (!account.isTotpEnabled()) return new TwoFactorStatus(false);
        if (!passwordEncoder.matches(body.currentPassword(), account.getPasswordHash())) {
            throw new ApiException(HttpStatus.UNAUTHORIZED, "当前密码不正确");
        }
        String attemptKey = twoFactorActionKey(request, account);
        if (!rateLimiter.allowed(attemptKey)) {
            throw new ApiException(HttpStatus.TOO_MANY_REQUESTS, "验证码尝试过多，请稍后再试");
        }
        if (!totp.verify(decryptSecret(account), body.code(), Instant.now())) {
            rateLimiter.failed(attemptKey);
            throw new ApiException(HttpStatus.UNAUTHORIZED, "验证码错误或已过期");
        }
        rateLimiter.succeeded(attemptKey);
        account.setTotpSecretCiphertext(null);
        account.setTotpEnabled(false);
        users.save(account);
        audit.record("USER_2FA_DISABLE", "user:" + account.getId(), "停用双因素认证");
        return new TwoFactorStatus(false);
    }

    @GetMapping("/me")
    UserDtos.View me(Authentication authentication) {
        return current(authentication);
    }

    @PutMapping("/profile")
    UserDtos.View profile(@Valid @RequestBody UserDtos.ProfileUpdateRequest body,
                          Authentication authentication, HttpServletRequest request) {
        UserDtos.View updated = userService.updateProfile(authentication.getName(), body);
        if (body.newPassword() != null && !body.newPassword().isBlank()) {
            request.changeSessionId();
        }
        return updated;
    }

    private UserDtos.View current(Authentication authentication) {
        UserAccount account = account(authentication);
        return new UserDtos.View(account.getId(), account.getUsername(), account.getDisplayName(), account.getRole(), account.isEnabled(),
                account.isTotpEnabled(), account.getCreatedAt());
    }

    private UserAccount account(Authentication authentication) {
        return users.findByUsernameIgnoreCase(authentication.getName())
                .orElseThrow(() -> new ApiException(HttpStatus.UNAUTHORIZED, "会话已失效"));
    }

    private String decryptSecret(UserAccount account) {
        if (!secrets.available() || account.getTotpSecretCiphertext() == null) {
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "双因素认证密钥不可用，请联系管理员");
        }
        try {
            return secrets.decrypt(account.getTotpSecretCiphertext());
        } catch (IllegalStateException exception) {
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "双因素认证密钥不可用，请联系管理员");
        }
    }

    private String setupSecret(HttpSession session) {
        if (session == null) throw new ApiException(HttpStatus.BAD_REQUEST, "请先生成双因素认证密钥");
        String secret = (String) session.getAttribute(SETUP_SECRET);
        Long expiresAt = (Long) session.getAttribute(SETUP_EXPIRES_AT);
        if (secret == null || expiresAt == null || expiresAt < System.currentTimeMillis()) {
            clearSetup(session);
            throw new ApiException(HttpStatus.BAD_REQUEST, "二维码已过期，请重新生成");
        }
        return secret;
    }

    private String twoFactorActionKey(HttpServletRequest request, UserAccount account) {
        return "2fa-action:" + request.getRemoteAddr() + ":" + account.getUsername().toLowerCase();
    }

    private void establishAuthentication(Authentication authentication, HttpServletRequest request, HttpServletResponse response) {
        request.getSession(true);
        request.changeSessionId();
        SecurityContext context = SecurityContextHolder.createEmptyContext();
        context.setAuthentication(authentication);
        SecurityContextHolder.setContext(context);
        new HttpSessionSecurityContextRepository().saveContext(context, request, response);
    }

    private void clearAuthentication(HttpServletRequest request, HttpServletResponse response) {
        SecurityContext empty = SecurityContextHolder.createEmptyContext();
        SecurityContextHolder.setContext(empty);
        new HttpSessionSecurityContextRepository().saveContext(empty, request, response);
    }

    private void clearPending(HttpSession session) {
        if (session == null) return;
        session.removeAttribute(PENDING_USERNAME);
        session.removeAttribute(PENDING_RETURN_TO);
        session.removeAttribute(PENDING_EXPIRES_AT);
    }

    private void clearSetup(HttpSession session) {
        if (session == null) return;
        session.removeAttribute(SETUP_SECRET);
        session.removeAttribute(SETUP_EXPIRES_AT);
    }

    private String safeReturn(String value) {
        if (value == null || !value.startsWith("/") || value.startsWith("//") || value.contains("://")) return "/dashboard";
        return value;
    }

    public record LoginRequest(@NotBlank String username, @NotBlank String password, String returnTo) {}
    public record LoginResponse(UserDtos.View user, String returnTo, boolean requiresTwoFactor) {}
    public record TwoFactorStatus(boolean enabled) {}
    public record TwoFactorSetup(String secret, String otpauthUri, Instant expiresAt) {}
    public record CurrentPasswordRequest(@NotBlank String currentPassword) {}
    public record CodeRequest(@NotBlank @Pattern(regexp = "\\d{6}") String code) {}
    public record DisableTwoFactorRequest(@NotBlank String currentPassword,
                                          @NotBlank @Pattern(regexp = "\\d{6}") String code) {}
    public record TwoFactorVerifyRequest(@NotBlank @Pattern(regexp = "\\d{6}") String code, String returnTo) {}
}
