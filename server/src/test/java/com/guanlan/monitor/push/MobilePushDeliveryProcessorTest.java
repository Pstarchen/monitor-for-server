package com.guanlan.monitor.push;

import com.guanlan.monitor.config.AppProperties;
import com.guanlan.monitor.config.PushKitProperties;
import com.guanlan.monitor.domain.MobileInstallation;
import com.guanlan.monitor.domain.MobilePushDelivery;
import com.guanlan.monitor.repository.MobilePushDeliveryRepository;
import com.guanlan.monitor.service.SecretValueCodec;
import org.junit.jupiter.api.Test;

import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class MobilePushDeliveryProcessorTest {
    @Test
    void marksQueuedDeliverySkippedWhenPushKitIsDisabledByDefault() {
        MobilePushDeliveryRepository repository = mock(MobilePushDeliveryRepository.class);
        PushKitClient client = mock(PushKitClient.class);
        when(client.enabled()).thenReturn(false);
        MobileInstallation installation = new MobileInstallation();
        installation.setEnabled(true);
        MobilePushDelivery delivery = new MobilePushDelivery();
        delivery.setStatus(MobilePushDelivery.Status.PENDING);
        delivery.setInstallation(installation);
        when(repository.lockById(9L)).thenReturn(Optional.of(delivery));
        PushKitProperties properties = new PushKitProperties();
        MobilePushDeliveryProcessor processor = new MobilePushDeliveryProcessor(repository, client, properties,
                new SecretValueCodec(new AppProperties()));

        processor.process(9L);

        assertThat(delivery.getStatus()).isEqualTo(MobilePushDelivery.Status.SKIPPED);
        assertThat(delivery.getLastError()).isEqualTo("PushKit is disabled");
        assertThat(delivery.getAttempts()).isZero();
    }
}
