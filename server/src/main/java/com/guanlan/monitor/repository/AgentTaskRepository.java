package com.guanlan.monitor.repository;

import com.guanlan.monitor.domain.AgentTask;
import jakarta.persistence.LockModeType;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;

public interface AgentTaskRepository extends JpaRepository<AgentTask, Long> {
    @Query("select task from AgentTask task join fetch task.device where task.id = :id")
    java.util.Optional<AgentTask> findWithDevice(@Param("id") Long id);
    List<AgentTask> findAllByOrderByCreatedAtDesc(Pageable pageable);

    List<AgentTask> findAllByDeviceIdOrderByCreatedAtDesc(String deviceId, Pageable pageable);

    List<AgentTask> findByStatus(AgentTask.Status status);

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("select task from AgentTask task where task.device.id = :deviceId and task.status = :status order by task.createdAt asc")
    List<AgentTask> findQueuedForDevice(@Param("deviceId") String deviceId, @Param("status") AgentTask.Status status, Pageable pageable);
}
