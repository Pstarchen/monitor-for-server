package com.guanlan.monitor.repository;

import com.guanlan.monitor.domain.AgentRollout;
import com.guanlan.monitor.domain.AgentRolloutMember;
import jakarta.persistence.LockModeType;
import org.springframework.data.jpa.repository.EntityGraph;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Collection;
import java.util.List;
import java.util.Optional;

public interface AgentRolloutMemberRepository extends JpaRepository<AgentRolloutMember, Long> {
    @EntityGraph(attributePaths = {"device", "task"})
    List<AgentRolloutMember> findByRolloutIdOrderByOrderIndex(Long rolloutId);

    @Query("select member.device.id from AgentRolloutMember member "
            + "where member.rollout.id = :rolloutId order by member.device.id")
    List<String> findDeviceIdsByRolloutIdOrderByDeviceId(@Param("rolloutId") Long rolloutId);

    @Query("select count(member) from AgentRolloutMember member "
            + "where member.rollout.id <> :rolloutId and member.device.id in :deviceIds "
            + "and (member.rollout.status in :activeStatuses "
            + "or (member.rollout.status = :canceledStatus and member.status in :canceledInFlightStatuses))")
    long countConflictingRollouts(@Param("rolloutId") Long rolloutId,
                                 @Param("deviceIds") Collection<String> deviceIds,
                                 @Param("activeStatuses") Collection<AgentRollout.Status> activeStatuses,
                                 @Param("canceledStatus") AgentRollout.Status canceledStatus,
                                 @Param("canceledInFlightStatuses") Collection<AgentRolloutMember.Status> canceledInFlightStatuses);

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("select member from AgentRolloutMember member "
            + "join fetch member.rollout rollout join fetch member.device "
            + "left join fetch member.task where member.id = :id")
    Optional<AgentRolloutMember> lockById(@Param("id") Long id);

    long countByRolloutIdAndStatusIn(Long rolloutId, Collection<AgentRolloutMember.Status> statuses);
}
