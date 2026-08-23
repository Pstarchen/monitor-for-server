package com.guanlan.monitor.repository;

import com.guanlan.monitor.domain.ApiToken;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

public interface ApiTokenRepository extends JpaRepository<ApiToken, Long> {
    Optional<ApiToken> findByTokenHashAndRevokedAtIsNull(String tokenHash);
    List<ApiToken> findAllByUserIdOrderByCreatedAtDesc(Long userId);
    Optional<ApiToken> findByIdAndUserId(Long id, Long userId);
    boolean existsByTokenHash(String tokenHash);
}
