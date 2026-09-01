package com.guanlan.monitor.service;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.api.dto.ClientBootstrapDtos;
import com.guanlan.monitor.config.AppProperties;
import com.guanlan.monitor.config.RealtimeProperties;
import com.guanlan.monitor.config.PushKitProperties;
import com.guanlan.monitor.domain.SystemSetting;
import com.guanlan.monitor.repository.SystemSettingRepository;
import com.guanlan.monitor.security.ApiTokenPrincipal;
import jakarta.annotation.PostConstruct;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.info.BuildProperties;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.Authentication;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.UUID;

@Service
@RequiredArgsConstructor(onConstructor_ = @Autowired)
public class ControllerIdentityService {
    private static final String CONTROLLER_ID_KEY = "controller.id";
    private final SystemSettingRepository settings;
    private final AppProperties appProperties;
    private final RealtimeProperties realtimeProperties;
    private final PushKitConfigurationService pushKitConfigurations;
    private final ObjectProvider<BuildProperties> buildProperties;
    private volatile String cachedControllerId;

    public ControllerIdentityService(SystemSettingRepository settings, AppProperties appProperties,
                                     RealtimeProperties realtimeProperties, PushKitProperties pushKitProperties,
                                     ObjectProvider<BuildProperties> buildProperties) {
        this(settings, appProperties, realtimeProperties, new PushKitConfigurationService(pushKitProperties), buildProperties);
    }

    @PostConstruct
    void initializeControllerId() {
        cachedControllerId = loadControllerId();
    }

    @Transactional
    public String controllerId() {
        String current = cachedControllerId;
        if (current != null) return current;
        synchronized (this) {
            if (cachedControllerId == null) cachedControllerId = loadControllerId();
            return cachedControllerId;
        }
    }

    private String loadControllerId() {
        SystemSetting setting = settings.findById(CONTROLLER_ID_KEY)
                .orElseGet(() -> settings.save(new SystemSetting(CONTROLLER_ID_KEY, UUID.randomUUID().toString())));
        try {
            return UUID.fromString(setting.getValue()).toString();
        } catch (IllegalArgumentException exception) {
            throw new IllegalStateException("Persisted controller ID is invalid", exception);
        }
    }

    @Transactional
    public ClientBootstrapDtos.Bootstrap bootstrap(Authentication authentication) {
        if (authentication == null || !authentication.isAuthenticated()) {
            throw new ApiException(HttpStatus.UNAUTHORIZED, "会话已失效");
        }
        ApiTokenPrincipal token = authentication.getPrincipal() instanceof ApiTokenPrincipal principal ? principal : null;
        Set<String> scopes = token == null ? Set.of() : token.scopes();
        Set<String> serverIds = token == null ? Set.of() : token.serverIds();
        String authenticationType = token == null ? "session" : "bearer";
        List<String> capabilities = new ArrayList<>(List.of(
                "client-bootstrap-v1", "mobile-diagnostics-v1", "alert-cursor-v2"));
        if (realtimeProperties.isEnabled()) capabilities.add("realtime-v2");
        if (pushKitConfigurations.runtime().enabled()) capabilities.add("mobile-push-v1");

        BuildProperties build = buildProperties.getIfAvailable();
        String version = build == null ? "" : build.getVersion();
        Instant buildTime = build == null ? null : build.getTime();
        return new ClientBootstrapDtos.Bootstrap(
                new ClientBootstrapDtos.Controller(controllerId(), appProperties.getSiteName(),
                        normalize(appProperties.getPublicBaseUrl()), appProperties.getTimezone()),
                new ClientBootstrapDtos.Server(version, buildTime, 2, 1, Instant.now()),
                List.copyOf(capabilities),
                new ClientBootstrapDtos.Principal(authenticationType, authentication.getName(),
                        role(authentication), token == null ? null : token.tokenId(),
                        token == null ? null : token.tokenPrefix(), scopes, serverIds,
                        token == null ? null : token.expiresAt()));
    }

    private String role(Authentication authentication) {
        return authentication.getAuthorities().stream()
                .map(authority -> authority.getAuthority())
                .filter(value -> value.startsWith("ROLE_"))
                .map(value -> value.substring("ROLE_".length()))
                .findFirst().orElse("VIEWER");
    }

    private String normalize(String value) {
        return value == null ? "" : value.trim();
    }
}
