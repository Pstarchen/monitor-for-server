package com.guanlan.monitor.repository;

import com.guanlan.monitor.domain.UserDevicePermission;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

public interface UserDevicePermissionRepository extends JpaRepository<UserDevicePermission, Long> {
    List<UserDevicePermission> findByUserId(Long userId);
    Optional<UserDevicePermission> findByUserUsernameIgnoreCaseAndDeviceId(String username, String deviceId);
    void deleteByUserId(Long userId);
}
