package com.guanlan.monitor.api;

import com.guanlan.monitor.api.dto.MobileInstallationDtos;
import com.guanlan.monitor.service.MobileInstallationService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

@RestController
@RequestMapping("/api/mobile/installations")
@RequiredArgsConstructor
public class MobileInstallationController {
    private final MobileInstallationService installations;

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    MobileInstallationDtos.View create(Authentication authentication,
                                       @Valid @RequestBody MobileInstallationDtos.CreateRequest request) {
        return installations.create(authentication, request);
    }

    @GetMapping
    List<MobileInstallationDtos.View> list(Authentication authentication) {
        return installations.list(authentication);
    }

    @PatchMapping("/{id}/token")
    MobileInstallationDtos.View updateToken(Authentication authentication, @PathVariable String id,
                                            @Valid @RequestBody MobileInstallationDtos.TokenUpdateRequest request) {
        return installations.updateToken(authentication, id, request);
    }

    @PutMapping("/{id}/token")
    MobileInstallationDtos.View replaceToken(Authentication authentication, @PathVariable String id,
                                             @Valid @RequestBody MobileInstallationDtos.TokenUpdateRequest request) {
        return installations.updateToken(authentication, id, request);
    }

    @PatchMapping("/{id}/preferences")
    MobileInstallationDtos.View updatePreferences(Authentication authentication, @PathVariable String id,
                                                  @Valid @RequestBody MobileInstallationDtos.PreferencesRequest request) {
        return installations.updatePreferences(authentication, id, request);
    }

    @PutMapping("/{id}/preferences")
    MobileInstallationDtos.View replacePreferences(Authentication authentication, @PathVariable String id,
                                                   @Valid @RequestBody MobileInstallationDtos.PreferencesRequest request) {
        return installations.updatePreferences(authentication, id, request);
    }

    @DeleteMapping("/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    void delete(Authentication authentication, @PathVariable String id) {
        installations.delete(authentication, id);
    }

    @PostMapping("/{id}/test")
    MobileInstallationDtos.TestResult test(Authentication authentication, @PathVariable String id) {
        return installations.test(authentication, id);
    }
}
