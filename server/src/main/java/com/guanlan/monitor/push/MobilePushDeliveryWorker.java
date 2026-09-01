package com.guanlan.monitor.push;

import com.guanlan.monitor.domain.MobilePushDelivery;
import com.guanlan.monitor.repository.MobilePushDeliveryRepository;
import com.guanlan.monitor.service.PushKitConfigurationService;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.PageRequest;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.time.Instant;
import java.util.List;

@Component
@RequiredArgsConstructor
public class MobilePushDeliveryWorker {
    private final MobilePushDeliveryRepository deliveries;
    private final MobilePushDeliveryProcessor processor;
    private final PushKitConfigurationService configurations;

    @Scheduled(fixedDelayString = "${app.push-kit.delivery-delay-ms:1000}", initialDelay = 7_000)
    public void deliver() {
        int batchSize = configurations.runtime().batchSize();
        List<Long> ids = deliveries.findReadyIds(
                List.of(MobilePushDelivery.Status.PENDING, MobilePushDelivery.Status.RETRY),
                Instant.now(), PageRequest.of(0, batchSize));
        for (Long id : ids) processor.process(id);
    }
}
