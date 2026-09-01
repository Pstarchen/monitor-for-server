package com.guanlan.monitor.api.dto;

import java.time.Instant;
import java.util.List;
import java.util.Set;

public final class ClientBootstrapDtos {
    private ClientBootstrapDtos() {}

    public record Bootstrap(
            Controller controller,
            Server server,
            List<String> capabilities,
            Principal principal
    ) {}

    public record Controller(String id, String name, String canonicalEntry, String timezone) {}

    public record Server(String version, Instant buildTime, int apiVersion,
                         int minimumClientApiVersion, Instant serverTime) {}

    public record Principal(
            String authenticationType,
            String username,
            String role,
            Long tokenId,
            String tokenPrefix,
            Set<String> scopes,
            Set<String> serverIds,
            Instant expiresAt
    ) {}
}
