package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.ApiTokenDtos;
import com.guanlan.monitor.security.ApiTokenPrincipal;
import com.guanlan.monitor.service.ApiTokenService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/api-tokens")
@RequiredArgsConstructor
public class ApiTokenController {
    private final ApiTokenService tokens;

    @GetMapping
    List<ApiTokenDtos.View> list(Authentication authentication) {
        requireSession(authentication);
        return tokens.list(authentication.getName());
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    ApiTokenDtos.Created create(Authentication authentication, @Valid @RequestBody ApiTokenDtos.CreateRequest request) {
        requireSession(authentication);
        return tokens.create(authentication.getName(), request);
    }

    @DeleteMapping("/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    void revoke(Authentication authentication, @PathVariable Long id) {
        requireSession(authentication);
        tokens.revoke(authentication.getName(), id);
    }

    private void requireSession(Authentication authentication) {
        if (authentication == null || authentication.getPrincipal() instanceof ApiTokenPrincipal) {
            throw new ApiException(HttpStatus.FORBIDDEN, "API Token 不能管理 API Token");
        }
    }
}
