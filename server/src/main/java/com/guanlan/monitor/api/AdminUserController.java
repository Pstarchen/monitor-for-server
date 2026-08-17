package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.UserDtos;
import com.guanlan.monitor.service.UserService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/admin/users")
@RequiredArgsConstructor
@PreAuthorize("hasRole('ADMIN')")
public class AdminUserController {
    private final UserService users;

    @GetMapping
    List<UserDtos.View> list() { return users.list(); }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    UserDtos.View create(@Valid @RequestBody UserDtos.CreateRequest request) { return users.create(request); }

    @PutMapping("/{id}")
    UserDtos.View update(@PathVariable Long id, @Valid @RequestBody UserDtos.UpdateRequest request) { return users.update(id, request); }
}

