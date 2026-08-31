package com.guanlan.monitor.repository;

import com.guanlan.monitor.domain.DiscoveryResult;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;

public interface DiscoveryResultRepository extends JpaRepository<DiscoveryResult, Long> {
    List<DiscoveryResult> findAllByScanIdOrderByDiscoveredAtDesc(Long scanId);
}
