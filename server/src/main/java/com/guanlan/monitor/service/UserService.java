package com.guanlan.monitor.service;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.api.dto.UserDtos;
import com.guanlan.monitor.domain.UserAccount;
import com.guanlan.monitor.repository.UserAccountRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Service
@RequiredArgsConstructor
public class UserService {
    private final UserAccountRepository users;
    private final PasswordEncoder passwordEncoder;
    private final AuditService audit;

    @Transactional(readOnly = true)
    public List<UserDtos.View> list() {
        return users.findAll().stream().map(this::view).toList();
    }

    @Transactional
    public UserDtos.View create(UserDtos.CreateRequest request) {
        if (users.findByUsernameIgnoreCase(request.username()).isPresent()) {
            throw new ApiException(HttpStatus.CONFLICT, "用户名已存在");
        }
        UserAccount user = new UserAccount();
        user.setUsername(request.username());
        user.setDisplayName(request.displayName());
        user.setPasswordHash(passwordEncoder.encode(request.password()));
        user.setRole(request.role());
        user.setEnabled(true);
        users.save(user);
        audit.record("USER_CREATE", "user:" + user.getId(), "创建账号 " + user.getUsername() + "，角色 " + user.getRole());
        return view(user);
    }

    @Transactional
    public UserDtos.View update(Long id, UserDtos.UpdateRequest request) {
        UserAccount user = users.findById(id).orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "用户不存在"));
        boolean removesAdmin = user.getRole() == UserAccount.Role.ADMIN && (request.role() != UserAccount.Role.ADMIN || !request.enabled());
        if (removesAdmin && users.countByRoleAndEnabledTrue(UserAccount.Role.ADMIN) <= 1) {
            throw new ApiException(HttpStatus.CONFLICT, "必须保留至少一个可用管理员");
        }
        user.setDisplayName(request.displayName());
        user.setRole(request.role());
        user.setEnabled(request.enabled());
        if (request.newPassword() != null && !request.newPassword().isBlank()) {
            user.setPasswordHash(passwordEncoder.encode(request.newPassword()));
        }
        audit.record("USER_UPDATE", "user:" + id, "更新账号 " + user.getUsername());
        return view(user);
    }

    private UserDtos.View view(UserAccount user) {
        return new UserDtos.View(user.getId(), user.getUsername(), user.getDisplayName(), user.getRole(), user.isEnabled(), user.getCreatedAt());
    }
}

