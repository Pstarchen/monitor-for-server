package com.guanlan.monitor.service;

import com.guanlan.monitor.domain.AgentRollout;
import com.guanlan.monitor.domain.AgentRolloutMember;
import com.guanlan.monitor.repository.AgentRolloutRepository;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.time.Instant;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

@Slf4j
@Component
@RequiredArgsConstructor
public class AgentRolloutWorker {
    private final AgentRolloutRepository rollouts;
    private final AgentRolloutService service;

    @Scheduled(fixedDelayString = "${app.agent-rollout.worker-delay-ms:5000}", initialDelay = 8_000)
    public void advance() {
        Set<Long> ids = new LinkedHashSet<>(rollouts.findProcessableIds(
                List.of(AgentRollout.Status.RUNNING, AgentRollout.Status.ROLLING_BACK)));
        ids.addAll(rollouts.findCanceledWithInFlightMembers(
                AgentRollout.Status.CANCELED,
                List.of(AgentRolloutMember.Status.QUEUED, AgentRolloutMember.Status.ACCEPTED,
                        AgentRolloutMember.Status.ROLLBACK_QUEUED,
                        AgentRolloutMember.Status.ROLLBACK_ACCEPTED)));
        for (Long id : ids) {
            try {
                service.advance(id, Instant.now());
            } catch (RuntimeException exception) {
                log.error("Failed to advance agent rollout {}", id, exception);
            }
        }
    }
}
