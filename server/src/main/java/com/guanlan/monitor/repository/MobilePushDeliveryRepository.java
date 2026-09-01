package com.guanlan.monitor.repository;

import com.guanlan.monitor.domain.MobilePushDelivery;
import jakarta.persistence.LockModeType;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.time.Instant;
import java.util.Collection;
import java.util.List;
import java.util.Optional;

public interface MobilePushDeliveryRepository extends JpaRepository<MobilePushDelivery, Long> {
    boolean existsByOutboxEventIdAndInstallationId(String eventId, String installationId);
    List<MobilePushDelivery> findByInstallationIdOrderByCreatedAtDesc(String installationId, Pageable pageable);

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("select delivery from MobilePushDelivery delivery where delivery.id = :id")
    Optional<MobilePushDelivery> lockById(@Param("id") Long id);

    @Query("select delivery.id from MobilePushDelivery delivery where delivery.status in :statuses "
            + "and delivery.nextAttemptAt <= :now order by delivery.id")
    List<Long> findReadyIds(@Param("statuses") Collection<MobilePushDelivery.Status> statuses,
                            @Param("now") Instant now, Pageable pageable);
}
