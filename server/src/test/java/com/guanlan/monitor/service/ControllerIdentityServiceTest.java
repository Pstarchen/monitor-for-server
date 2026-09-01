package com.guanlan.monitor.service;

import com.guanlan.monitor.config.AppProperties;
import com.guanlan.monitor.config.PushKitProperties;
import com.guanlan.monitor.config.RealtimeProperties;
import com.guanlan.monitor.domain.SystemSetting;
import com.guanlan.monitor.repository.SystemSettingRepository;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.info.BuildProperties;

import java.util.Optional;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.stream.IntStream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ControllerIdentityServiceTest {
    @Test
    @SuppressWarnings("unchecked")
    void initializesIdentityOnceForConcurrentFirstAccess() throws Exception {
        SystemSettingRepository settings = mock(SystemSettingRepository.class);
        when(settings.findById(anyString())).thenReturn(Optional.empty());
        when(settings.save(any())).thenAnswer(invocation -> invocation.getArgument(0));
        ControllerIdentityService service = new ControllerIdentityService(
                settings, new AppProperties(), new RealtimeProperties(), new PushKitProperties(),
                mock(ObjectProvider.class));
        CountDownLatch start = new CountDownLatch(1);

        try (var executor = Executors.newFixedThreadPool(8)) {
            var futures = IntStream.range(0, 16)
                    .mapToObj(ignored -> executor.submit(() -> {
                        start.await();
                        return service.controllerId();
                    }))
                    .toList();
            start.countDown();
            Set<String> identities = futures.stream()
                    .map(future -> {
                        try {
                            return future.get(5, TimeUnit.SECONDS);
                        } catch (Exception exception) {
                            throw new AssertionError(exception);
                        }
                    })
                    .collect(java.util.stream.Collectors.toSet());

            assertThat(identities).hasSize(1);
        }
        verify(settings, times(1)).save(any(SystemSetting.class));
    }
}
