package com.guanlan.monitor.security;

import com.guanlan.monitor.config.AppProperties;
import com.guanlan.monitor.domain.UserAccount;
import com.guanlan.monitor.repository.UserAccountRepository;
import lombok.RequiredArgsConstructor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.context.annotation.Profile;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

@Component
@Profile("!bootstrap")
@RequiredArgsConstructor
public class BootstrapAdmin implements ApplicationRunner {
    private static final Logger log = LoggerFactory.getLogger(BootstrapAdmin.class);
    private final UserAccountRepository users;
    private final PasswordEncoder passwordEncoder;
    private final AppProperties properties;

    @Override
    @Transactional
    public void run(ApplicationArguments args) {
        if (users.existsByRole(UserAccount.Role.ADMIN)) return;
        String username = properties.getBootstrapAdminUsername();
        String password = properties.getBootstrapAdminPassword();
        if (username == null || username.isBlank() || password == null || password.length() < 12) {
            log.warn("No administrator exists. Set BOOTSTRAP_ADMIN_USERNAME and a password of at least 12 characters.");
            return;
        }
        UserAccount admin = new UserAccount();
        admin.setUsername(username.trim());
        admin.setDisplayName("系统管理员");
        admin.setPasswordHash(passwordEncoder.encode(password));
        admin.setRole(UserAccount.Role.ADMIN);
        admin.setEnabled(true);
        users.save(admin);
        log.info("Bootstrap administrator created for username {}", username.trim());
    }
}
