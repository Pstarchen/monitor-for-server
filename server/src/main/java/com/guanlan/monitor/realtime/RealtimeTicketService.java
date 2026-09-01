package com.guanlan.monitor.realtime;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.config.AppProperties;
import com.guanlan.monitor.config.RealtimeProperties;
import com.guanlan.monitor.security.ApiTokenPrincipal;
import lombok.RequiredArgsConstructor;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.http.HttpStatus;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.stereotype.Service;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

@Service
@RequiredArgsConstructor
public class RealtimeTicketService {
    private static final String REDIS_PREFIX = "monitor:realtime:ticket:";
    private final StringRedisTemplate redis;
    private final ObjectMapper mapper;
    private final AppProperties appProperties;
    private final RealtimeProperties properties;
    private final RealtimeOutboxService outbox;
    private final SecureRandom random = new SecureRandom();
    private final ConcurrentHashMap<String, TicketClaims> localTickets = new ConcurrentHashMap<>();

    public IssuedTicket issue(Authentication authentication, String requestedAfterEventId) {
        if (authentication == null || !authentication.isAuthenticated()) {
            throw new ApiException(HttpStatus.UNAUTHORIZED, "会话已失效");
        }
        ApiTokenPrincipal tokenPrincipal = authentication.getPrincipal() instanceof ApiTokenPrincipal principal
                ? principal : null;
        if (tokenPrincipal != null && !tokenPrincipal.allowsScope("nezha:realtime:read")) {
            throw new ApiException(HttpStatus.FORBIDDEN, "需要 nezha:realtime:read 权限");
        }
        String after = requestedAfterEventId == null ? outbox.latestEventId() : requestedAfterEventId.trim();
        // Validate retention boundaries before issuing a single-use credential.
        outbox.replay(authentication, after, 1);

        byte[] bytes = new byte[32];
        random.nextBytes(bytes);
        String ticket = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
        String digest = fingerprint(ticket);
        Instant expiresAt = Instant.now().plusSeconds(Math.max(5, properties.getTicketTtlSeconds()));
        List<String> authorities = authentication.getAuthorities().stream().map(GrantedAuthority::getAuthority).toList();
        TicketClaims claims = new TicketClaims(authentication.getName(),
                tokenPrincipal == null ? null : tokenPrincipal.tokenId(), authorities,
                tokenPrincipal == null ? Set.of() : tokenPrincipal.scopes(),
                tokenPrincipal == null ? Set.of() : tokenPrincipal.serverIds(),
                tokenPrincipal != null, after, expiresAt);
        store(digest, claims);
        return new IssuedTicket(ticket, expiresAt, "/ws/realtime", outbox.latestEventId());
    }

    public ConsumedTicket consume(String ticket) {
        if (ticket == null || ticket.isBlank()) throw new ApiException(HttpStatus.UNAUTHORIZED, "实时连接凭据缺失");
        String digest = fingerprint(ticket.trim());
        TicketClaims claims = consumeStored(digest);
        if (claims == null || !claims.expiresAt().isAfter(Instant.now())) {
            throw new ApiException(HttpStatus.UNAUTHORIZED, "实时连接凭据无效或已过期");
        }
        Authentication authentication;
        if (claims.apiToken()) {
            String role = claims.authorities().stream()
                    .filter(value -> value.startsWith("ROLE_"))
                    .map(value -> value.substring(5))
                    .findFirst().orElse("VIEWER");
            ApiTokenPrincipal principal = new ApiTokenPrincipal(claims.tokenId(), claims.username(), role,
                    claims.scopes(), claims.serverIds());
            authentication = new UsernamePasswordAuthenticationToken(principal, "", principal.getAuthorities());
        } else {
            List<SimpleGrantedAuthority> authorities = claims.authorities().stream()
                    .map(SimpleGrantedAuthority::new).toList();
            authentication = new UsernamePasswordAuthenticationToken(claims.username(), "", authorities);
        }
        return new ConsumedTicket(authentication, claims.afterEventId());
    }

    private void store(String digest, TicketClaims claims) {
        Duration ttl = Duration.between(Instant.now(), claims.expiresAt());
        if (appProperties.isRedisEnabled()) {
            try {
                redis.opsForValue().set(REDIS_PREFIX + digest, mapper.writeValueAsString(claims), ttl);
                return;
            } catch (Exception ignored) {
                // A node-local ticket keeps a single-node deployment available while Redis recovers.
            }
        }
        purgeExpiredLocalTickets();
        localTickets.put(digest, claims);
    }

    private TicketClaims consumeStored(String digest) {
        if (appProperties.isRedisEnabled()) {
            try {
                String json = redis.opsForValue().getAndDelete(REDIS_PREFIX + digest);
                if (json != null) return mapper.readValue(json, TicketClaims.class);
            } catch (Exception ignored) {
                // Only tickets explicitly stored in the local fallback are eligible here.
            }
        }
        return localTickets.remove(digest);
    }

    private void purgeExpiredLocalTickets() {
        Instant now = Instant.now();
        localTickets.entrySet().removeIf(entry -> !entry.getValue().expiresAt().isAfter(now));
    }

    private String fingerprint(String ticket) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(ticket.getBytes(StandardCharsets.UTF_8));
            return java.util.HexFormat.of().formatHex(digest);
        } catch (Exception exception) {
            throw new IllegalStateException("SHA-256 unavailable", exception);
        }
    }

    private record TicketClaims(String username, Long tokenId, List<String> authorities, Set<String> scopes,
                                Set<String> serverIds, boolean apiToken, String afterEventId,
                                Instant expiresAt) {}
    public record IssuedTicket(String ticket, Instant expiresAt, String socketPath,
                               String latestEventId) {}
    public record ConsumedTicket(Authentication authentication, String afterEventId) {}
}
