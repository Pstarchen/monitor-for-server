package com.guanlan.monitor.config;

import jakarta.annotation.PostConstruct;
import lombok.RequiredArgsConstructor;
import org.springframework.core.env.Environment;
import org.springframework.stereotype.Component;

/** Prevents a production deployment from silently starting against bootstrap H2. */
@Component
@RequiredArgsConstructor
public class ProductionConfigurationGuard {
    private final Environment environment;

    @PostConstruct
    void validate() {
        if (!environment.matchesProfiles("production")) {
            return;
        }

        String databaseUrl = environment.getProperty("spring.datasource.url", "").trim();
        if (!databaseUrl.startsWith("jdbc:postgresql://")) {
            throw new IllegalStateException("生产环境必须使用内置 PostgreSQL，禁止使用 bootstrap H2 数据库");
        }

        String encryptionKey = environment.getProperty("app.settings-encryption-key", "").trim();
        if (encryptionKey.isEmpty()) {
            throw new IllegalStateException("生产环境缺少 SETTINGS_ENCRYPTION_KEY");
        }
    }
}
