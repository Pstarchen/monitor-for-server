package com.guanlan.monitor.repository;

import com.guanlan.monitor.domain.AlertEvent;
import com.guanlan.monitor.domain.AlertRule;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Collection;
import java.util.List;
import java.util.Optional;
import java.time.Instant;

public interface AlertEventRepository extends JpaRepository<AlertEvent, Long> {
    List<AlertEvent> findAllByOrderByStartedAtDesc(Pageable pageable);
    @Query("""
            select event from AlertEvent event
            where (:status is null or event.status = :status)
              and (:severity is null or event.rule.severity = :severity)
              and (:deviceId is null or event.device.id = :deviceId)
            order by event.startedAt desc
            """)
    List<AlertEvent> search(@Param("status") AlertEvent.Status status,
                            @Param("severity") AlertRule.Severity severity,
                            @Param("deviceId") String deviceId,
                            Pageable pageable);
    Optional<AlertEvent> findFirstByDeviceIdAndRuleIdAndStatusInOrderByStartedAtDesc(
            String deviceId, Long ruleId, Collection<AlertEvent.Status> statuses);
    long countByStatusIn(Collection<AlertEvent.Status> statuses);
    long countByDeviceIdInAndStatusIn(Collection<String> deviceIds, Collection<AlertEvent.Status> statuses);
    long countByRuleId(Long ruleId);
    List<AlertEvent> findByStartedAtBetweenOrderByStartedAtDesc(Instant from, Instant to);
}
