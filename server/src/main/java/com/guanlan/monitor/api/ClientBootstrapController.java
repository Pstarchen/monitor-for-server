package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.ClientBootstrapDtos;
import com.guanlan.monitor.service.ControllerIdentityService;
import lombok.RequiredArgsConstructor;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/client")
@RequiredArgsConstructor
public class ClientBootstrapController {
    private final ControllerIdentityService identity;

    @GetMapping("/bootstrap")
    ClientBootstrapDtos.Bootstrap bootstrap(Authentication authentication) {
        return identity.bootstrap(authentication);
    }
}
