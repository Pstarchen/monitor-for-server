package com.guanlan.monitor.repository;

import com.guanlan.monitor.domain.DeviceNote;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;

public interface DeviceNoteRepository extends JpaRepository<DeviceNote, Long> {
    List<DeviceNote> findByDeviceIdOrderByCreatedAtDesc(String deviceId, Pageable pageable);
    List<DeviceNote> findAllByOrderByCreatedAtDesc(Pageable pageable);
}
