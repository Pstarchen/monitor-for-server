package com.guanlan.monitor.repository;

import com.guanlan.monitor.domain.AlertEvent;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Collection;
import java.util.List;
import java.util.Optional;

public interface AlertEventRepository extends JpaRepository<AlertEvent, Long> {
    List<AlertEvent> findAllByOrderByStartedAtDesc(Pageable pageable);
    Optional<AlertEvent> findFirstByDeviceIdAndRuleIdAndStatusInOrderByStartedAtDesc(
            String deviceId, Long ruleId, Collection<AlertEvent.Status> statuses);
    long countByStatusIn(Collection<AlertEvent.Status> statuses);
    long countByDeviceIdInAndStatusIn(Collection<String> deviceIds, Collection<AlertEvent.Status> statuses);
    long countByRuleId(Long ruleId);
}
