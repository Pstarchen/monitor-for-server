package com.guanlan.monitor.repository;

import com.guanlan.monitor.domain.DeviceStatusEvent;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

import java.time.Instant;
import java.util.List;

public interface DeviceStatusEventRepository extends JpaRepository<DeviceStatusEvent, Long> {
    List<DeviceStatusEvent> findByDeviceIdAndChangedAtBetweenOrderByChangedAtDesc(String deviceId, Instant from, Instant to, Pageable pageable);
    long deleteByChangedAtBefore(Instant cutoff);
}
