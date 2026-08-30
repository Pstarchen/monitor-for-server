package com.guanlan.monitor.repository;

import com.guanlan.monitor.domain.NotificationDelivery;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;

public interface NotificationDeliveryRepository extends JpaRepository<NotificationDelivery, Long> {
    List<NotificationDelivery> findAllByOrderByCreatedAtDesc(Pageable pageable);
}
