package com.guanlan.monitor.repository;

import com.guanlan.monitor.domain.AgentRollout;
import com.guanlan.monitor.domain.AgentRolloutMember;
import jakarta.persistence.LockModeType;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Collection;
import java.util.List;
import java.util.Optional;

public interface AgentRolloutRepository extends JpaRepository<AgentRollout, Long> {
    List<AgentRollout> findAllByOrderByCreatedAtDesc(Pageable pageable);

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("select rollout from AgentRollout rollout where rollout.id = :id")
    Optional<AgentRollout> lockById(@Param("id") Long id);

    @Query("select rollout.id from AgentRollout rollout where rollout.status in :statuses order by rollout.updatedAt, rollout.id")
    List<Long> findProcessableIds(@Param("statuses") Collection<AgentRollout.Status> statuses);

    @Query("select distinct rollout.id from AgentRolloutMember member join member.rollout rollout "
            + "where rollout.status = :rolloutStatus and member.status in :memberStatuses order by rollout.id")
    List<Long> findCanceledWithInFlightMembers(
            @Param("rolloutStatus") AgentRollout.Status rolloutStatus,
            @Param("memberStatuses") Collection<AgentRolloutMember.Status> memberStatuses);
}
