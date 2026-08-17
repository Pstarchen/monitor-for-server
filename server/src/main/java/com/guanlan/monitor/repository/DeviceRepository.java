package com.guanlan.monitor.repository;

import com.guanlan.monitor.domain.Device;
import org.springframework.data.jpa.repository.JpaRepository;

import java.time.Instant;
import java.util.List;

public interface DeviceRepository extends JpaRepository<Device, String> {
    List<Device> findAllByOrderByNameAsc();
    List<Device> findByStatusNotAndLastSeenAtBefore(Device.Status status, Instant cutoff);
    long countByStatus(Device.Status status);
}

