package com.guanlan.monitor.config;

import com.guanlan.monitor.push.PushKitServiceAccount;
import com.guanlan.monitor.service.PushKitConfigurationService;
import jakarta.annotation.PostConstruct;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

@Component
@RequiredArgsConstructor
public class PushKitConfigurationGuard {
    private final PushKitConfigurationService configurations;
    private final PushKitServiceAccount serviceAccount;

    @PostConstruct
    void validate() {
        PushKitConfigurationService.Runtime runtime = configurations.runtime();
        if (!runtime.enabled()) return;
        serviceAccount.validate(runtime);
    }
}
