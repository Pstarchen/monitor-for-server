package com.guanlan.monitor.repository;

import com.guanlan.monitor.domain.MaintenanceWindow;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;

public interface MaintenanceWindowRepository extends JpaRepository<MaintenanceWindow, Long> {
    List<MaintenanceWindow> findAllByOrderByStartsAtDesc();
    List<MaintenanceWindow> findByEnabledTrue();
}
