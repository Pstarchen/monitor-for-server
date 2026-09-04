package com.guanlan.monitor.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.service.ApiTokenService;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.web.authentication.WebAuthenticationDetailsSource;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.Map;

@Component
@RequiredArgsConstructor
public class ApiTokenAuthenticationFilter extends OncePerRequestFilter {
    private static final String DENY_SCOPE = "__token_scope_denied__";
    private final ApiTokenService tokens;
    private final ObjectMapper mapper;

    public boolean isApiTokenRequest(HttpServletRequest request) {
        return bearerToken(request) != null;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain) throws ServletException, IOException {
        String secret = bearerToken(request);
        if (secret == null) {
            chain.doFilter(request, response);
            return;
        }
        var principal = tokens.authenticate(secret, request.getRemoteAddr()).orElse(null);
        if (principal == null) {
            error(response, HttpStatus.UNAUTHORIZED, "API Token 无效或已过期");
            return;
        }
        String requiredScope = requiredScope(request);
        if (DENY_SCOPE.equals(requiredScope) || !principal.allowsScope(requiredScope)) {
            error(response, HttpStatus.FORBIDDEN, "API Token 缺少所需权限", requiredScope);
            return;
        }
        if (!serverAllowed(principal, request)) {
            error(response, HttpStatus.FORBIDDEN, "API Token 未获准访问该服务器");
            return;
        }
        var authentication = new UsernamePasswordAuthenticationToken(principal, secret, principal.getAuthorities());
        authentication.setDetails(new WebAuthenticationDetailsSource().buildDetails(request));
        SecurityContextHolder.getContext().setAuthentication(authentication);
        chain.doFilter(request, response);
    }

    private String bearerToken(HttpServletRequest request) {
        String value = request.getHeader("Authorization");
        if (value == null || !value.regionMatches(true, 0, "Bearer ", 0, 7)) return null;
        String token = value.substring(7).trim();
        return token.startsWith("nzp_") ? token : null;
    }

    private String requiredScope(HttpServletRequest request) {
        String path = request.getRequestURI();
        String method = request.getMethod();
        if (path.equals("/mcp")) return method.equals("POST") ? null : DENY_SCOPE;
        // API tokens cannot inspect or mutate the browser session/account
        // endpoints. ApiTokenController also enforces this at the handler
        // boundary; deny it here so a token never reaches those handlers.
        if (path.startsWith("/api/api-tokens") || path.equals("/api/auth/me")) return DENY_SCOPE;
        if (method.equals("GET") && (path.equals("/api/auth/csrf")
                || path.equals("/api/settings/public")
                || path.equals("/api/settings/site-icon")
                || path.equals("/api/public/overview")
                || path.equals("/api/services/public")
                || path.equals("/actuator/health")
                || path.equals("/actuator/info"))) return null;
        if (path.startsWith("/api/admin/")) return "nezha:admin:*";
        if (path.equals("/api/client/bootstrap")) return method.equals("GET") ? "nezha:inventory:read" : DENY_SCOPE;
        if (path.equals("/api/dashboard")) return method.equals("GET") ? "nezha:inventory:read" : DENY_SCOPE;
        if (path.equals("/api/topology")) return method.equals("GET") ? "nezha:inventory:read" : DENY_SCOPE;
        if (path.equals("/api/device-access/me")) return method.equals("GET") ? "nezha:inventory:read" : DENY_SCOPE;
        if (path.equals("/api/device-notes/recent")) return method.equals("GET") ? "nezha:inventory:read" : DENY_SCOPE;
        if (path.equals("/api/devices")) return switch (method) {
            case "GET" -> "nezha:inventory:read";
            case "POST" -> "nezha:server:write";
            default -> DENY_SCOPE;
        };
        if (path.startsWith("/api/v2/devices/")) return method.equals("GET") ? "nezha:server:read" : DENY_SCOPE;
        if (path.startsWith("/api/devices/")) {
            if (path.endsWith("/rotate-key")) return method.equals("POST") ? "nezha:server:write" : DENY_SCOPE;
            if (path.endsWith("/enrollment-token")) return method.equals("POST") ? "nezha:server:write" : DENY_SCOPE;
            if (path.contains("/metrics/")) return method.equals("GET") ? "nezha:server:read" : DENY_SCOPE;
            if (path.contains("/notes")) return switch (method) {
                case "GET" -> "nezha:server:read";
                case "POST" -> "nezha:server:write";
                case "DELETE" -> "nezha:inventory:delete";
                default -> DENY_SCOPE;
            };
            return switch (method) {
                case "GET" -> "nezha:server:read";
                case "PUT" -> "nezha:server:write";
                case "DELETE" -> "nezha:inventory:delete";
                default -> DENY_SCOPE;
            };
        }
        if (path.startsWith("/api/services")) return resourceScope("service", method);
        if (path.startsWith("/api/ddns")) return method.equals("GET") ? "nezha:ddns:read" : resourceScope("ddns", method);
        if (path.equals("/api/tasks/update")) return "nezha:admin:*";
        if (path.startsWith("/api/tasks")) return switch (method) {
            case "GET" -> "nezha:server:read";
            case "POST" -> "nezha:server:exec";
            default -> DENY_SCOPE;
        };
        if (path.startsWith("/api/alert-rules")) return resourceScope("alertrule", method);
        if (path.startsWith("/api/v2/alerts") || path.startsWith("/api/alerts")) return switch (method) {
            case "GET" -> "nezha:alert:read";
            case "POST" -> "nezha:alert:write";
            default -> DENY_SCOPE;
        };
        if (path.startsWith("/api/maintenance-windows")) return resourceScope("maintenance", method);
        if (path.startsWith("/api/realtime")) return switch (method) {
            case "GET", "POST" -> "nezha:realtime:read";
            default -> DENY_SCOPE;
        };
        if (path.startsWith("/api/mobile/installations")) {
            return switch (method) {
                case "GET" -> "nezha:push:read";
                case "POST", "PUT", "PATCH" -> "nezha:push:write";
                case "DELETE" -> "nezha:push:delete";
                default -> DENY_SCOPE;
            };
        }
        if (path.startsWith("/api/settings")) return "nezha:admin:*";
        return DENY_SCOPE;
    }

    private String resourceScope(String resource, String method) {
        return switch (method) {
            case "GET" -> "nezha:" + resource + ":read";
            case "POST", "PUT" -> "nezha:" + resource + ":write";
            case "DELETE" -> "nezha:" + resource + ":delete";
            default -> DENY_SCOPE;
        };
    }

    private boolean serverAllowed(ApiTokenPrincipal principal, HttpServletRequest request) {
        if (principal.serverIds().isEmpty()) return true;
        String path = request.getRequestURI();
        if (!path.startsWith("/api/devices/")) return true;
        String rest = path.substring("/api/devices/".length());
        int separator = rest.indexOf('/');
        String id = separator < 0 ? rest : rest.substring(0, separator);
        return !id.isBlank() && principal.serverIds().contains(id);
    }

    private void error(HttpServletResponse response, HttpStatus status, String message) throws IOException {
        error(response, status, message, null);
    }

    private void error(HttpServletResponse response, HttpStatus status, String message, String requiredScope) throws IOException {
        response.setStatus(status.value());
        response.setContentType("application/json;charset=UTF-8");
        Map<String, String> body = new LinkedHashMap<>();
        body.put("message", message);
        if (requiredScope != null && !requiredScope.equals(DENY_SCOPE)) body.put("requiredScope", requiredScope);
        mapper.writeValue(response.getOutputStream(), body);
    }
}
