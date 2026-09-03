package com.guanlan.monitor.repository;

import com.guanlan.monitor.domain.Device;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.time.Instant;
import java.util.List;
import java.util.Optional;

public interface DeviceRepository extends JpaRepository<Device, String> {
    List<Device> findAllByOrderByNameAsc();
    List<Device> findByStatusNotAndLastSeenAtBefore(Device.Status status, Instant cutoff);
    Optional<Device> findByIdAndAgentEnrollmentTokenHashAndAgentEnrollmentTokenExpiresAtAfterAndControllerManagedFalse(
            String id, String tokenHash, Instant now);

    @Modifying(clearAutomatically = true, flushAutomatically = true)
    @Query("""
            update Device device
               set device.agentKeyHash = :agentKeyHash,
                   device.agentKeyPrefix = :agentKeyPrefix,
                   device.agentEnrollmentTokenHash = null,
                   device.agentEnrollmentTokenExpiresAt = null,
                   device.updatedAt = :updatedAt
             where device.id = :id
               and device.agentEnrollmentTokenHash = :tokenHash
               and device.agentEnrollmentTokenExpiresAt > :now
               and device.controllerManaged = false
            """)
    int consumeEnrollmentToken(@Param("id") String id,
                               @Param("tokenHash") String tokenHash,
                               @Param("now") Instant now,
                               @Param("agentKeyHash") String agentKeyHash,
                               @Param("agentKeyPrefix") String agentKeyPrefix,
                               @Param("updatedAt") Instant updatedAt);

    long countByStatus(Device.Status status);
}
