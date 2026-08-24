package com.guanlan.monitor.repository;

import com.guanlan.monitor.domain.ServiceCheckResult;
import org.springframework.data.jpa.repository.JpaRepository;

import java.time.Instant;
import java.util.List;
import java.util.Optional;

public interface ServiceCheckResultRepository extends JpaRepository<ServiceCheckResult, Long> {
    Optional<ServiceCheckResult> findTopByServiceCheckIdOrderByCheckedAtDesc(Long serviceCheckId);
    List<ServiceCheckResult> findTop60ByServiceCheckIdOrderByCheckedAtDesc(Long serviceCheckId);
    List<ServiceCheckResult> findByServiceCheckIdAndCheckedAtBetweenOrderByCheckedAtAsc(Long serviceCheckId, Instant from, Instant to);
    long countByServiceCheckIdAndCheckedAtBetween(Long serviceCheckId, Instant from, Instant to);
    long countByServiceCheckIdAndSuccessTrueAndCheckedAtBetween(Long serviceCheckId, Instant from, Instant to);
    long deleteByCheckedAtBefore(Instant cutoff);
    long deleteByServiceCheckId(Long serviceCheckId);
}
