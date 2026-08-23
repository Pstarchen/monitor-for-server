package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.DdnsDtos;
import com.guanlan.monitor.service.DdnsService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/ddns")
@RequiredArgsConstructor
public class DdnsController {
    private final DdnsService ddns;

    @GetMapping @PreAuthorize("hasAnyRole('ADMIN','OPERATOR','VIEWER')")
    List<DdnsDtos.View> list(Authentication authentication) {
        boolean includeErrorDetails = authentication != null && authentication.getAuthorities().stream()
                .anyMatch(authority -> authority.getAuthority().equals("ROLE_ADMIN") || authority.getAuthority().equals("ROLE_OPERATOR"));
        return ddns.list(includeErrorDetails);
    }
    @PostMapping @ResponseStatus(HttpStatus.CREATED) @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    DdnsDtos.View create(Authentication authentication, @Valid @RequestBody DdnsDtos.Request request) { return ddns.create(request, authentication.getName()); }

    @PutMapping("/{id}") @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    DdnsDtos.View update(Authentication authentication, @PathVariable Long id, @Valid @RequestBody DdnsDtos.Request request) { return ddns.update(id, request, authentication.getName()); }

    @DeleteMapping("/{id}") @ResponseStatus(HttpStatus.NO_CONTENT) @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    void delete(Authentication authentication, @PathVariable Long id) { ddns.delete(id, authentication.getName()); }

    @PostMapping("/{id}/test") @PreAuthorize("hasAnyRole('ADMIN','OPERATOR')")
    DdnsDtos.View test(Authentication authentication, @PathVariable Long id, @RequestParam String ip) { return ddns.test(id, ip, authentication.getName()); }
}
