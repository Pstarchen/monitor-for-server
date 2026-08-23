package com.guanlan.monitor.repository;

import com.guanlan.monitor.domain.ServiceCheck;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;

public interface ServiceCheckRepository extends JpaRepository<ServiceCheck, Long> {
    List<ServiceCheck> findAllByOrderBySortOrderDescNameAsc();
    List<ServiceCheck> findByEnabledTrueOrderBySortOrderDescNameAsc();
}
