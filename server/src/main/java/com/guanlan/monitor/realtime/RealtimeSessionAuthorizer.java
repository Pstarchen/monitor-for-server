package com.guanlan.monitor.realtime;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.domain.ApiToken;
import com.guanlan.monitor.domain.UserAccount;
import com.guanlan.monitor.repository.ApiTokenRepository;
import com.guanlan.monitor.repository.UserAccountRepository;
import com.guanlan.monitor.security.ApiTokenPrincipal;
import lombok.RequiredArgsConstructor;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.Set;

@Service
@RequiredArgsConstructor
public class RealtimeSessionAuthorizer {
    private static final TypeReference<List<String>> STRING_LIST = new TypeReference<>() {};
    private final ApiTokenRepository tokens;
    private final UserAccountRepository users;
    private final ObjectMapper mapper;

    @Transactional(readOnly = true)
    public Optional<Authentication> refresh(Authentication authentication) {
        if (authentication == null || !authentication.isAuthenticated()) return Optional.empty();
        if (authentication.getPrincipal() instanceof ApiTokenPrincipal principal) {
            ApiToken token = tokens.findByIdAndRevokedAtIsNull(principal.tokenId()).orElse(null);
            if (token == null || token.getExpiresAt() != null && !token.getExpiresAt().isAfter(Instant.now())
                    || !token.getUser().isEnabled()) return Optional.empty();
            Set<String> scopes = Set.copyOf(parse(token.getScopesJson()));
            ApiTokenPrincipal current = new ApiTokenPrincipal(token.getId(), token.getUser().getUsername(),
                    token.getUser().getRole().name(), scopes, Set.copyOf(parse(token.getServerIdsJson())));
            if (!current.allowsScope("nezha:realtime:read")) return Optional.empty();
            return Optional.of(new UsernamePasswordAuthenticationToken(current, "", current.getAuthorities()));
        }

        UserAccount user = users.findByUsernameIgnoreCase(authentication.getName()).orElse(null);
        if (user == null || !user.isEnabled()) return Optional.empty();
        return Optional.of(new UsernamePasswordAuthenticationToken(user.getUsername(), "",
                List.of(new SimpleGrantedAuthority("ROLE_" + user.getRole().name()))));
    }

    private List<String> parse(String value) {
        if (value == null || value.isBlank()) return List.of();
        try {
            return mapper.readValue(value, STRING_LIST);
        } catch (Exception exception) {
            return List.of();
        }
    }
}
