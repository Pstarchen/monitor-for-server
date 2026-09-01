package com.guanlan.monitor.security;

import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.userdetails.UserDetails;

import java.util.Collection;
import java.time.Instant;
import java.util.List;
import java.util.Set;

public final class ApiTokenPrincipal implements UserDetails {
    private final Long tokenId;
    private final String username;
    private final Set<String> scopes;
    private final Set<String> serverIds;
    private final String tokenPrefix;
    private final Instant expiresAt;
    private final List<GrantedAuthority> authorities;

    public ApiTokenPrincipal(Long tokenId, String username, String role, Set<String> scopes, Set<String> serverIds) {
        this(tokenId, username, role, scopes, serverIds, null, null);
    }

    public ApiTokenPrincipal(Long tokenId, String username, String role, Set<String> scopes, Set<String> serverIds,
                             String tokenPrefix, Instant expiresAt) {
        this.tokenId = tokenId;
        this.username = username;
        this.scopes = Set.copyOf(scopes);
        this.serverIds = Set.copyOf(serverIds);
        this.tokenPrefix = tokenPrefix;
        this.expiresAt = expiresAt;
        this.authorities = List.of(new SimpleGrantedAuthority("ROLE_" + role));
    }

    public Long tokenId() { return tokenId; }
    public Set<String> scopes() { return scopes; }
    public Set<String> serverIds() { return serverIds; }
    public String tokenPrefix() { return tokenPrefix; }
    public Instant expiresAt() { return expiresAt; }

    public boolean allowsScope(String required) {
        if (required == null || required.isBlank()) return true;
        if (scopes.contains("nezha:*") || scopes.contains(required)) return true;
        int separator = required.lastIndexOf(':');
        if (separator > 0 && scopes.contains(required.substring(0, separator) + ":*")) return true;
        return false;
    }

    @Override public Collection<? extends GrantedAuthority> getAuthorities() { return authorities; }
    @Override public String getPassword() { return ""; }
    @Override public String getUsername() { return username; }
    @Override public boolean isAccountNonExpired() { return true; }
    @Override public boolean isAccountNonLocked() { return true; }
    @Override public boolean isCredentialsNonExpired() { return true; }
    @Override public boolean isEnabled() { return true; }
}
