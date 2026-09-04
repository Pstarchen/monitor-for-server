package com.guanlan.monitor.repository;

import com.guanlan.monitor.domain.AgentTask;
import jakarta.persistence.LockModeType;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.time.Instant;

public interface AgentTaskRepository extends JpaRepository<AgentTask, Long> {
    @Query("select task from AgentTask task join fetch task.device where task.id = :id")
    java.util.Optional<AgentTask> findWithDevice(@Param("id") Long id);
    List<AgentTask> findAllByOrderByCreatedAtDesc(Pageable pageable);

    List<AgentTask> findAllByDeviceIdOrderByCreatedAtDesc(String deviceId, Pageable pageable);

    List<AgentTask> findByStatus(AgentTask.Status status);

    @Modifying(flushAutomatically = true)
    @Query("update AgentTask task set task.status = :canceled, task.finishedAt = :finishedAt, task.error = :error "
            + "where task.id = :id and task.status = :queued")
    int cancelIfQueued(@Param("id") Long id,
                       @Param("queued") AgentTask.Status queued,
                       @Param("canceled") AgentTask.Status canceled,
                       @Param("finishedAt") Instant finishedAt,
                       @Param("error") String error);

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("select task from AgentTask task where task.device.id = :deviceId and task.status = :status order by task.createdAt asc")
    List<AgentTask> findQueuedForDevice(@Param("deviceId") String deviceId, @Param("status") AgentTask.Status status, Pageable pageable);
}
