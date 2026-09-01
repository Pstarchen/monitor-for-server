package com.guanlan.monitor.push;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.core.type.TypeReference;
import com.guanlan.monitor.config.PushKitProperties;
import com.guanlan.monitor.domain.MobileInstallation;
import com.guanlan.monitor.domain.MobilePushDelivery;
import com.guanlan.monitor.domain.RealtimeOutboxEvent;
import com.guanlan.monitor.domain.ApiToken;
import com.guanlan.monitor.repository.MobileInstallationRepository;
import com.guanlan.monitor.repository.MobilePushDeliveryRepository;
import com.guanlan.monitor.repository.RealtimeOutboxRepository;
import com.guanlan.monitor.security.ApiTokenPrincipal;
import com.guanlan.monitor.service.DeviceAccessService;
import lombok.RequiredArgsConstructor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.domain.PageRequest;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.Map;
import java.util.List;
import java.util.Set;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;

@Component
@RequiredArgsConstructor
public class MobilePushFanoutWorker {
    private static final Logger log = LoggerFactory.getLogger(MobilePushFanoutWorker.class);
    private final RealtimeOutboxRepository outbox;
    private final MobileInstallationRepository installations;
    private final MobilePushDeliveryRepository deliveries;
    private final DeviceAccessService access;
    private final ObjectMapper mapper;
    private final PushKitProperties properties;

    @Scheduled(fixedDelayString = "${app.push-kit.fanout-delay-ms:1000}", initialDelay = 5_000)
    @Transactional
    public void fanout() {
        int batchSize = Math.min(Math.max(properties.getBatchSize(), 1), 200);
        for (RealtimeOutboxEvent event : outbox.lockPendingPushFanout(PageRequest.of(0, batchSize))) {
            try {
                fanout(event);
                event.setPushFanoutAt(Instant.now());
            } catch (Exception exception) {
                log.warn("Mobile push fanout failed for {}: {}", event.getEventId(), exception.getClass().getSimpleName());
            }
        }
    }

    private void fanout(RealtimeOutboxEvent event) throws Exception {
        JsonNode payload = mapper.readTree(event.getPayloadJson());
        Notification notification = notification(event, payload);
        for (MobileInstallation installation : installations.findByEnabledTrue()) {
            Authentication authentication = installationAuthentication(installation);
            if (!authorized(installation, authentication, event, payload)
                    || !preferenceEnabled(installation, event.getEventType(), payload)) continue;
            if (deliveries.existsByOutboxEventIdAndInstallationId(event.getEventId(), installation.getId())) continue;
            MobilePushDelivery delivery = new MobilePushDelivery();
            delivery.setOutboxEventId(event.getEventId());
            delivery.setInstallation(installation);
            delivery.setEventType(event.getEventType());
            delivery.setTitle(notification.title());
            delivery.setBody(notification.body());
            delivery.setDataJson(mapper.writeValueAsString(Map.of(
                    "controllerId", event.getControllerId(),
                    "eventType", event.getEventType(),
                    "alertId", payload.path("alertId").asText(""),
                    "deviceId", event.getDeviceId() == null ? "" : event.getDeviceId(),
                    "severity", payload.path("severity").asText(""),
                    "occurredAt", event.getOccurredAt().toString())));
            deliveries.save(delivery);
        }
    }

    private boolean preferenceEnabled(MobileInstallation installation, String eventType, JsonNode payload) {
        if (!eventType.startsWith("alert.") && !"device.status".equals(eventType)) return false;
        if (eventType.startsWith("alert.")) {
            String severity = payload.path("severity").asText("WARNING");
            try {
                return AlertSeverity.rank(severity) >= AlertSeverity.rank(installation.getMinimumSeverity().name());
            } catch (IllegalArgumentException exception) {
                return false;
            }
        }
        return true;
    }

    private boolean authorized(MobileInstallation installation, Authentication authentication,
                               RealtimeOutboxEvent event, JsonNode payload) {
        ApiToken token = installation.getApiToken();
        if (token == null || token.getRevokedAt() != null
                || token.getExpiresAt() != null && !token.getExpiresAt().isAfter(Instant.now())
                || !token.getUser().isEnabled()) return false;
        if (!tokenPrincipal(authentication).allowsScope("nezha:alert:read")) return false;
        String deviceId = event.getDeviceId();
        if (deviceId == null || !access.canView(authentication, deviceId)) return false;
        List<String> deviceIds = deviceIds(installation.getDeviceIdsJson());
        return deviceIds.isEmpty() || deviceIds.contains(deviceId);
    }

    private Authentication installationAuthentication(MobileInstallation installation) {
        ApiToken token = installation.getApiToken();
        if (token == null) return null;
        ApiTokenPrincipal principal = new ApiTokenPrincipal(token.getId(), token.getUser().getUsername(),
                token.getUser().getRole().name(), strings(token.getScopesJson()), strings(token.getServerIdsJson()));
        return new UsernamePasswordAuthenticationToken(principal, "", principal.getAuthorities());
    }

    private ApiTokenPrincipal tokenPrincipal(Authentication authentication) {
        return authentication == null || !(authentication.getPrincipal() instanceof ApiTokenPrincipal principal)
                ? new ApiTokenPrincipal(null, "", "VIEWER", Set.of(), Set.of()) : principal;
    }

    private List<String> deviceIds(String value) {
        if (value == null || value.isBlank()) return List.of();
        try {
            return mapper.readValue(value, new TypeReference<List<String>>() {});
        } catch (Exception exception) {
            // A corrupt scope must fail closed rather than broadening push access.
            return List.of("__invalid_scope__");
        }
    }

    private Set<String> strings(String value) {
        return Set.copyOf(stringsList(value));
    }

    private List<String> stringsList(String value) {
        if (value == null || value.isBlank()) return List.of();
        try {
            return mapper.readValue(value, new TypeReference<List<String>>() {});
        } catch (Exception exception) {
            return List.of();
        }
    }

    private Notification notification(RealtimeOutboxEvent event, JsonNode payload) {
        if (event.getEventType().startsWith("alert.")) {
            String severity = payload.path("severity").asText("WARNING");
            return new Notification(limit("星辰监控 · " + severity, 120), "有新的监控告警，请打开应用查看详情");
        }
        return new Notification("星辰监控 · 设备状态", "设备状态发生变化，请打开应用查看详情");
    }

    private String limit(String value, int length) {
        return value.length() <= length ? value : value.substring(0, length);
    }

    private record Notification(String title, String body) {}
    private enum AlertSeverity {
        INFO(1), WARNING(2), CRITICAL(3);

        private final int rank;

        AlertSeverity(int rank) { this.rank = rank; }

        static int rank(String value) { return valueOf(value.trim().toUpperCase()).rank; }
    }
}
