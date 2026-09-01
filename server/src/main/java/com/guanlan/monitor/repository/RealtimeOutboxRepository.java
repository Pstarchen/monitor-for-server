package com.guanlan.monitor.repository;

import com.guanlan.monitor.domain.RealtimeOutboxEvent;
import jakarta.persistence.LockModeType;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.time.Instant;
import java.util.List;
import java.util.Optional;

public interface RealtimeOutboxRepository extends JpaRepository<RealtimeOutboxEvent, Long> {
    Optional<RealtimeOutboxEvent> findByEventId(String eventId);

    List<RealtimeOutboxEvent> findByIdGreaterThanOrderByIdAsc(Long id, Pageable pageable);

    Optional<RealtimeOutboxEvent> findTopByOrderByIdDesc();
    Optional<RealtimeOutboxEvent> findTopByOrderByIdAsc();
    long countByIdGreaterThan(Long id);

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("select event from RealtimeOutboxEvent event "
            + "where event.publishedAt is null and event.availableAt <= :now order by event.id")
    List<RealtimeOutboxEvent> lockPending(@Param("now") Instant now, Pageable pageable);

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("select event from RealtimeOutboxEvent event where event.pushFanoutAt is null "
            + "and (event.eventType like 'alert.%' or event.eventType = 'device.status') order by event.id")
    List<RealtimeOutboxEvent> lockPendingPushFanout(Pageable pageable);

    @Modifying
    @Query("delete from RealtimeOutboxEvent event where event.publishedAt < :cutoff and "
            + "(event.pushFanoutAt is not null or (event.eventType not like 'alert.%' and event.eventType <> 'device.status'))")
    int deleteCompletedBefore(@Param("cutoff") Instant cutoff);
}
