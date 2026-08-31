package com.guanlan.monitor.repository;

import com.guanlan.monitor.domain.DiscoveryScan;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Collection;

public interface DiscoveryScanRepository extends JpaRepository<DiscoveryScan, Long> {
    List<DiscoveryScan> findAllByOrderByCreatedAtDesc(Pageable pageable);

    List<DiscoveryScan> findByStatusIn(Collection<DiscoveryScan.Status> statuses);
}
