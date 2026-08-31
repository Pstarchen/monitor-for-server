package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.TopologyDtos;
import com.guanlan.monitor.service.DeviceAccessService;
import com.guanlan.monitor.service.TopologyService;
import lombok.RequiredArgsConstructor;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Set;

@RestController
@RequestMapping("/api/topology")
@RequiredArgsConstructor
public class TopologyController {
    private final TopologyService topology;
    private final DeviceAccessService access;

    @GetMapping
    TopologyDtos.View get(Authentication authentication) {
        return topology.build(access.visibleDeviceIds(authentication));
    }
}
