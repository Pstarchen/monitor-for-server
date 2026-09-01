package com.guanlan.monitor.push;

import com.guanlan.monitor.config.PushKitProperties;
import com.guanlan.monitor.domain.MobileInstallation;
import com.guanlan.monitor.domain.MobilePushDelivery;
import com.guanlan.monitor.repository.MobilePushDeliveryRepository;
import com.guanlan.monitor.service.SecretValueCodec;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;

@Service
@RequiredArgsConstructor
public class MobilePushDeliveryProcessor {
    private final MobilePushDeliveryRepository deliveries;
    private final PushKitClient pushKit;
    private final PushKitProperties properties;
    private final SecretValueCodec secrets;

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void process(Long id) {
        MobilePushDelivery delivery = deliveries.lockById(id).orElse(null);
        if (delivery == null || delivery.getStatus() != MobilePushDelivery.Status.PENDING
                && delivery.getStatus() != MobilePushDelivery.Status.RETRY) return;
        MobileInstallation installation = delivery.getInstallation();
        if (!installation.isEnabled()) {
            skipped(delivery, "Mobile installation is disabled");
            return;
        }
        if (!pushKit.enabled()) {
            skipped(delivery, "PushKit is disabled");
            return;
        }

        delivery.setAttempts(delivery.getAttempts() + 1);
        try {
            PushKitClient.SendResult result = pushKit.send(secrets.decrypt(installation.getTokenCiphertext()),
                    delivery.getTitle(), delivery.getBody(), delivery.getDataJson(),
                    "push.test".equals(delivery.getEventType()));
            delivery.setStatus(MobilePushDelivery.Status.SENT);
            delivery.setProviderRequestId(limit(result.providerRequestId(), 128));
            delivery.setLastError(null);
            delivery.setSentAt(Instant.now());
        } catch (PushKitClient.PushKitException exception) {
            if (exception.invalidToken()) installation.setEnabled(false);
            failure(delivery, exception.getMessage(), exception.retryable());
        } catch (Exception exception) {
            failure(delivery, exception.getClass().getSimpleName(), false);
        }
    }

    private void failure(MobilePushDelivery delivery, String error, boolean retryable) {
        delivery.setLastError(limit(safe(error), 500));
        if (retryable && delivery.getAttempts() < Math.max(1, properties.getMaxAttempts())) {
            long delay = Math.min(900, 5L << Math.min(delivery.getAttempts() - 1, 7));
            delivery.setStatus(MobilePushDelivery.Status.RETRY);
            delivery.setNextAttemptAt(Instant.now().plusSeconds(delay));
        } else {
            delivery.setStatus(MobilePushDelivery.Status.FAILED);
        }
    }

    private void skipped(MobilePushDelivery delivery, String reason) {
        delivery.setStatus(MobilePushDelivery.Status.SKIPPED);
        delivery.setLastError(reason);
    }

    private String safe(String value) {
        if (value == null || value.isBlank()) return "Push delivery failed";
        return value.replaceAll("[\\r\\n\\t]+", " ").trim();
    }

    private String limit(String value, int max) {
        if (value == null) return null;
        return value.length() <= max ? value : value.substring(0, max);
    }
}
