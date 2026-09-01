package com.guanlan.monitor.config;

import com.guanlan.monitor.push.PushKitServiceAccount;
import jakarta.annotation.PostConstruct;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

@Component
@RequiredArgsConstructor
public class PushKitConfigurationGuard {
    private final PushKitProperties properties;
    private final PushKitServiceAccount serviceAccount;

    @PostConstruct
    void validate() {
        if (!properties.isEnabled()) return;
        serviceAccount.validate();
    }
}
