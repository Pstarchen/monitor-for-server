package com.guanlan.monitor.repository;

import com.guanlan.monitor.domain.UserAccount;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;

public interface UserAccountRepository extends JpaRepository<UserAccount, Long> {
    Optional<UserAccount> findByUsernameIgnoreCase(String username);
    boolean existsByRole(UserAccount.Role role);
    long countByRoleAndEnabledTrue(UserAccount.Role role);
}
