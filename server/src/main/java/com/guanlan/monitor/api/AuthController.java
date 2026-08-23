package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.UserDtos;
import com.guanlan.monitor.domain.UserAccount;
import com.guanlan.monitor.repository.UserAccountRepository;
import com.guanlan.monitor.security.LoginRateLimiter;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.security.authentication.AuthenticationManager;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContext;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.web.context.HttpSessionSecurityContextRepository;
import org.springframework.security.web.csrf.CsrfToken;
import org.springframework.web.bind.annotation.*;
import com.guanlan.monitor.service.UserService;

import java.util.Map;

@RestController
@RequestMapping("/api/auth")
@RequiredArgsConstructor
public class AuthController {
    private final AuthenticationManager authenticationManager;
    private final LoginRateLimiter rateLimiter;
    private final UserAccountRepository users;
    private final UserService userService;

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
            request.getSession(true);
            request.changeSessionId();
            SecurityContext context = SecurityContextHolder.createEmptyContext();
            context.setAuthentication(authentication);
            SecurityContextHolder.setContext(context);
            new HttpSessionSecurityContextRepository().saveContext(context, request, response);
            rateLimiter.succeeded(key);
            return new LoginResponse(current(authentication), safeReturn(body.returnTo()));
        } catch (org.springframework.security.core.AuthenticationException exception) {
            rateLimiter.failed(key);
            throw exception;
        }
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
        UserAccount account = users.findByUsernameIgnoreCase(authentication.getName())
                .orElseThrow(() -> new ApiException(HttpStatus.UNAUTHORIZED, "会话已失效"));
        return new UserDtos.View(account.getId(), account.getUsername(), account.getDisplayName(), account.getRole(), account.isEnabled(), account.getCreatedAt());
    }

    private String safeReturn(String value) {
        if (value == null || !value.startsWith("/") || value.startsWith("//") || value.contains("://")) return "/dashboard";
        return value;
    }

    public record LoginRequest(@NotBlank String username, @NotBlank String password, String returnTo) {}
    public record LoginResponse(UserDtos.View user, String returnTo) {}
}
