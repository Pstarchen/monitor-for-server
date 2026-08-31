package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.DiscoveryDtos;
import com.guanlan.monitor.service.NetworkDiscoveryService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

@RestController
@RequestMapping("/api/discovery")
@RequiredArgsConstructor
@PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
public class DiscoveryController {
    private final NetworkDiscoveryService discovery;

    @GetMapping
    List<DiscoveryDtos.View> list(Authentication authentication, @RequestParam(defaultValue = "20") int limit) {
        return discovery.list(limit, authentication);
    }

    @GetMapping("/{id}")
    DiscoveryDtos.Detail get(Authentication authentication, @PathVariable Long id) {
        return discovery.get(id, authentication);
    }

    @PostMapping
    @ResponseStatus(HttpStatus.ACCEPTED)
    DiscoveryDtos.View start(Authentication authentication, @Valid @RequestBody DiscoveryDtos.StartRequest request) {
        return discovery.start(request, authentication.getName(), authentication);
    }

    @PostMapping("/{id}/cancel")
    DiscoveryDtos.View cancel(Authentication authentication, @PathVariable Long id) {
        return discovery.cancel(id, authentication);
    }
}
