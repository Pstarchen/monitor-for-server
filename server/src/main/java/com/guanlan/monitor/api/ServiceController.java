package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.ServiceDtos;
import com.guanlan.monitor.service.ServiceMonitorService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.time.Instant;

@RestController
@RequestMapping("/api/services")
@RequiredArgsConstructor
public class ServiceController {
    private final ServiceMonitorService services;

    @GetMapping
    List<ServiceDtos.View> list() { return services.list(); }

    @GetMapping("/public")
    List<ServiceDtos.PublicView> publicList() { return services.listPublic(); }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    ServiceDtos.View create(@Valid @RequestBody ServiceDtos.Request request) { return services.create(request); }

    @PutMapping("/{id}")
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    ServiceDtos.View update(@PathVariable Long id, @Valid @RequestBody ServiceDtos.Request request) { return services.update(id, request); }

    @DeleteMapping("/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    void delete(@PathVariable Long id) { services.delete(id); }

    @PostMapping("/{id}/check")
    @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    ServiceDtos.View check(@PathVariable Long id) { return services.runNow(id); }

    @GetMapping("/{id}/history")
    List<ServiceDtos.ResultView> history(@PathVariable Long id, @RequestParam Instant from, @RequestParam Instant to) { return services.history(id, from, to); }
}
