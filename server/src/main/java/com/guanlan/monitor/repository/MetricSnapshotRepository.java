package com.guanlan.monitor.repository;

import com.guanlan.monitor.domain.MetricSnapshot;
import org.springframework.data.jpa.repository.JpaRepository;

import java.time.Instant;
import java.util.List;
import java.util.Optional;

public interface MetricSnapshotRepository extends JpaRepository<MetricSnapshot, Long> {
    Optional<MetricSnapshot> findTopByDeviceIdOrderByCollectedAtDesc(String deviceId);
    List<MetricSnapshot> findByDeviceIdAndCollectedAtBetweenOrderByCollectedAtAsc(String deviceId, Instant from, Instant to);
    long deleteByCollectedAtBefore(Instant cutoff);
}

