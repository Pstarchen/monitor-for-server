package com.guanlan.monitor.repository;

import com.guanlan.monitor.domain.MobileInstallation;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

public interface MobileInstallationRepository extends JpaRepository<MobileInstallation, String> {
    List<MobileInstallation> findByApiTokenIdOrderByUpdatedAtDesc(Long apiTokenId);
    List<MobileInstallation> findByEnabledTrue();
    Optional<MobileInstallation> findByApiTokenIdAndClientInstallationId(Long apiTokenId, String clientInstallationId);
    Optional<MobileInstallation> findByIdAndApiTokenId(String id, Long apiTokenId);
    boolean existsByTokenFingerprintAndIdNot(String tokenFingerprint, String id);
}
