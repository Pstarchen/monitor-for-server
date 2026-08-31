package com.guanlan.monitor.service;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.api.dto.UserDtos;
import com.guanlan.monitor.domain.Device;
import com.guanlan.monitor.domain.UserAccount;
import com.guanlan.monitor.domain.UserDevicePermission;
import com.guanlan.monitor.repository.DeviceRepository;
import com.guanlan.monitor.repository.UserAccountRepository;
import com.guanlan.monitor.repository.UserDevicePermissionRepository;
import com.guanlan.monitor.security.ApiTokenPrincipal;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.Authentication;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.Predicate;
import java.util.stream.Collectors;

@Service
@RequiredArgsConstructor
public class DeviceAccessService {
    private final UserAccountRepository users;
    private final DeviceRepository devices;
    private final UserDevicePermissionRepository permissions;
    private final AuditService audit;

    @Transactional(readOnly = true)
    public Set<String> visibleDeviceIds(Authentication authentication) {
        return allowedDeviceIds(authentication, UserDevicePermission::isCanView);
    }

    @Transactional(readOnly = true)
    public List<UserDtos.DevicePermissionView> current(Authentication authentication) {
        Set<String> visible = visibleDeviceIds(authentication);
        if (visible == null) {
            return devices.findAllByOrderByNameAsc().stream()
                    .map(device -> view(device, true, true, true, true))
                    .toList();
        }
        boolean admin = isAdmin(authentication);
        Map<String, UserDevicePermission> assigned = permissionMap(requireUser(authentication).getId());
        return devices.findAllByOrderByNameAsc().stream()
                .filter(device -> visible.contains(device.getId()))
                .map(device -> {
                    UserDevicePermission permission = assigned.get(device.getId());
                    return view(device, true, admin || permission != null && permission.isCanManage(),
                            admin || permission != null && permission.isCanAlert(),
                            admin || permission != null && permission.isCanTask());
                })
                .toList();
    }

    @Transactional(readOnly = true)
    public List<UserDtos.DevicePermissionView> listForUser(Long userId) {
        UserAccount user = requireUser(userId);
        Map<String, UserDevicePermission> assigned = permissionMap(userId);
        boolean admin = user.getRole() == UserAccount.Role.ADMIN;
        return devices.findAllByOrderByNameAsc().stream().map(device -> {
            UserDevicePermission permission = assigned.get(device.getId());
            return view(device, admin || permission != null && permission.isCanView(),
                    admin || permission != null && permission.isCanManage(),
                    admin || permission != null && permission.isCanAlert(),
                    admin || permission != null && permission.isCanTask());
        }).toList();
    }

    @Transactional
    public List<UserDtos.DevicePermissionView> replace(Long userId, UserDtos.DevicePermissionRequest request) {
        UserAccount user = requireUser(userId);
        if (user.getRole() == UserAccount.Role.ADMIN) {
            throw new ApiException(HttpStatus.CONFLICT, "管理员始终拥有全部设备权限，无需单独分配");
        }
        Map<String, UserDtos.DevicePermissionItem> requested = new LinkedHashMap<>();
        for (UserDtos.DevicePermissionItem item : request.permissions()) {
            if (requested.putIfAbsent(item.deviceId(), item) != null) {
                throw new ApiException(HttpStatus.BAD_REQUEST, "设备权限列表包含重复设备");
            }
        }
        Map<String, Device> knownDevices = devices.findAllById(requested.keySet()).stream()
                .collect(Collectors.toMap(Device::getId, device -> device));
        if (knownDevices.size() != requested.size()) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "设备权限列表包含不存在的设备");
        }
        permissions.deleteByUserId(userId);
        permissions.flush();
        for (UserDtos.DevicePermissionItem item : requested.values()) {
            boolean canView = item.canView() || item.canManage() || item.canAlert() || item.canTask();
            if (!canView) continue;
            UserDevicePermission permission = new UserDevicePermission();
            permission.setUser(user);
            permission.setDevice(knownDevices.get(item.deviceId()));
            permission.setCanView(true);
            permission.setCanManage(item.canManage());
            permission.setCanAlert(item.canAlert());
            permission.setCanTask(item.canTask());
            permissions.save(permission);
        }
        audit.record("USER_DEVICE_PERMISSIONS_UPDATE", "user:" + userId,
                "更新账号 " + user.getUsername() + " 的设备权限");
        return listForUser(userId);
    }

    @Transactional
    public void grantCreatorAccess(Authentication authentication, Device device) {
        if (authentication == null || isAdmin(authentication)) return;
        UserAccount user = requireUser(authentication);
        UserDevicePermission permission = permissions
                .findByUserUsernameIgnoreCaseAndDeviceId(user.getUsername(), device.getId())
                .orElseGet(UserDevicePermission::new);
        permission.setUser(user);
        permission.setDevice(device);
        permission.setCanView(true);
        permission.setCanManage(true);
        permission.setCanAlert(true);
        permission.setCanTask(true);
        permissions.save(permission);
    }

    @Transactional(readOnly = true)
    public void requireView(Authentication authentication, String deviceId) {
        require(authentication, deviceId, UserDevicePermission::isCanView, "无权查看该设备");
    }

    @Transactional(readOnly = true)
    public void requireManage(Authentication authentication, String deviceId) {
        require(authentication, deviceId, UserDevicePermission::isCanManage, "无权管理该设备");
    }

    @Transactional(readOnly = true)
    public void requireAlert(Authentication authentication, String deviceId) {
        require(authentication, deviceId, UserDevicePermission::isCanAlert, "无权处理该设备的告警");
    }

    @Transactional(readOnly = true)
    public void requireTask(Authentication authentication, String deviceId) {
        require(authentication, deviceId, UserDevicePermission::isCanTask, "无权在该设备执行任务");
    }

    @Transactional(readOnly = true)
    public boolean canManage(Authentication authentication, String deviceId) {
        return can(authentication, deviceId, UserDevicePermission::isCanManage);
    }

    @Transactional(readOnly = true)
    public boolean canView(Authentication authentication, String deviceId) {
        return can(authentication, deviceId, UserDevicePermission::isCanView);
    }

    @Transactional(readOnly = true)
    public boolean canAlert(Authentication authentication, String deviceId) {
        return can(authentication, deviceId, UserDevicePermission::isCanAlert);
    }

    @Transactional(readOnly = true)
    public boolean canTask(Authentication authentication, String deviceId) {
        return can(authentication, deviceId, UserDevicePermission::isCanTask);
    }

    @Transactional(readOnly = true)
    public void requireAlertScope(Authentication authentication, String deviceId) {
        if (deviceId != null && !deviceId.isBlank()) {
            requireAlert(authentication, deviceId);
            return;
        }
        if (authentication == null || !isAdmin(authentication) || tokenDeviceIds(authentication) != null) {
            throw new ApiException(HttpStatus.FORBIDDEN, "只有不受设备范围限制的管理员可以管理全局策略");
        }
    }

    private Set<String> allowedDeviceIds(Authentication authentication, Predicate<UserDevicePermission> permissionCheck) {
        if (authentication == null || !authentication.isAuthenticated()) return Set.of();
        Set<String> tokenIds = tokenDeviceIds(authentication);
        if (isAdmin(authentication)) return tokenIds;
        UserAccount user = requireUser(authentication);
        Set<String> assigned = permissions.findByUserId(user.getId()).stream()
                .filter(permissionCheck)
                .map(permission -> permission.getDevice().getId())
                .collect(Collectors.toSet());
        if (tokenIds == null) return Set.copyOf(assigned);
        assigned.retainAll(tokenIds);
        return Set.copyOf(assigned);
    }

    private void require(Authentication authentication, String deviceId,
                         Predicate<UserDevicePermission> permissionCheck, String message) {
        if (!can(authentication, deviceId, permissionCheck)) throw new ApiException(HttpStatus.FORBIDDEN, message);
    }

    private boolean can(Authentication authentication, String deviceId,
                        Predicate<UserDevicePermission> permissionCheck) {
        if (authentication == null || !authentication.isAuthenticated() || deviceId == null || deviceId.isBlank()) return false;
        Set<String> tokenIds = tokenDeviceIds(authentication);
        if (tokenIds != null && !tokenIds.contains(deviceId)) return false;
        if (isAdmin(authentication)) return true;
        return permissions.findByUserUsernameIgnoreCaseAndDeviceId(authentication.getName(), deviceId)
                .filter(permissionCheck)
                .isPresent();
    }

    private boolean isAdmin(Authentication authentication) {
        return authentication.getAuthorities().stream().anyMatch(authority -> "ROLE_ADMIN".equals(authority.getAuthority()));
    }

    private Set<String> tokenDeviceIds(Authentication authentication) {
        if (!(authentication.getPrincipal() instanceof ApiTokenPrincipal principal) || principal.serverIds().isEmpty()) return null;
        return principal.serverIds();
    }

    private UserAccount requireUser(Authentication authentication) {
        if (authentication == null || authentication.getName() == null) {
            throw new ApiException(HttpStatus.UNAUTHORIZED, "会话已失效");
        }
        return users.findByUsernameIgnoreCase(authentication.getName())
                .orElseThrow(() -> new ApiException(HttpStatus.UNAUTHORIZED, "会话已失效"));
    }

    private UserAccount requireUser(Long id) {
        return users.findById(id).orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "用户不存在"));
    }

    private Map<String, UserDevicePermission> permissionMap(Long userId) {
        return permissions.findByUserId(userId).stream()
                .collect(Collectors.toMap(permission -> permission.getDevice().getId(), permission -> permission));
    }

    private UserDtos.DevicePermissionView view(Device device, boolean canView, boolean canManage,
                                               boolean canAlert, boolean canTask) {
        return new UserDtos.DevicePermissionView(device.getId(), device.getName(), canView, canManage, canAlert, canTask);
    }
}
