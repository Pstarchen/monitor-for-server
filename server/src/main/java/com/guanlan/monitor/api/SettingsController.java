package com.guanlan.monitor.api;

import com.guanlan.monitor.service.NotificationService;
import com.guanlan.monitor.service.MobileInstallationService;
import com.guanlan.monitor.service.PushKitConfigurationService;
import com.guanlan.monitor.service.SettingService;
import com.guanlan.monitor.service.SiteIconStorageService;
import lombok.RequiredArgsConstructor;
import org.springframework.core.io.Resource;
import org.springframework.http.CacheControl;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestPart;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.multipart.MultipartFile;

@RestController
@RequestMapping("/api/settings")
@RequiredArgsConstructor
public class SettingsController {
    private final SettingService settings;
    private final NotificationService notifications;
    private final SiteIconStorageService siteIcons;
    private final PushKitConfigurationService pushKitConfigurations;
    private final MobileInstallationService mobileInstallations;

    @GetMapping("/public")
    ResponseEntity<SettingService.PublicBrandView> publicBrand() {
        return ResponseEntity.ok()
                .cacheControl(CacheControl.noStore())
                .body(settings.publicBrand());
    }

    @GetMapping("/site-icon")
    ResponseEntity<Resource> siteIcon() {
        return siteIcons.read()
                .map(icon -> ResponseEntity.ok()
                        .cacheControl(CacheControl.noCache())
                        .contentType(MediaType.parseMediaType(icon.contentType()))
                        .body(icon.resource()))
                .orElseGet(() -> ResponseEntity.notFound().build());
    }

    @GetMapping
    @PreAuthorize("hasRole('ADMIN')")
    SettingService.View get() { return settings.get(); }

    @GetMapping("/agent-bootstrap")
    @PreAuthorize("hasAnyRole('ADMIN', 'OPERATOR')")
    SettingService.AgentBootstrapView agentBootstrap() { return settings.agentBootstrap(); }

    @PutMapping
    @PreAuthorize("hasRole('ADMIN')")
    SettingService.View update(@RequestBody SettingService.Update request) { return settings.update(request); }

    @PostMapping(value = "/site-icon", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    @PreAuthorize("hasRole('ADMIN')")
    SettingService.View uploadSiteIcon(@RequestPart("file") MultipartFile file) {
        return settings.uploadSiteIcon(file);
    }

    @PostMapping("/notifications/{channel}/test")
    @PreAuthorize("hasRole('ADMIN')")
    NotificationService.TestResult test(@PathVariable String channel) { return notifications.test(channel); }

    @GetMapping("/notifications/deliveries")
    @PreAuthorize("hasRole('ADMIN')")
    java.util.List<NotificationService.NotificationDeliveryView> deliveries() { return notifications.listDeliveries(100); }

    @PostMapping("/notifications/deliveries/{id}/retry")
    @PreAuthorize("hasRole('ADMIN')")
    NotificationService.NotificationDeliveryView retry(@PathVariable long id) { return notifications.retry(id); }

    @PostMapping("/push-kit/validate")
    @PreAuthorize("hasRole('ADMIN')")
    PushKitConfigurationService.ValidationResult validatePushKit() {
        return pushKitConfigurations.validate();
    }

    @GetMapping("/push-kit/installations")
    @PreAuthorize("hasRole('ADMIN')")
    java.util.List<com.guanlan.monitor.api.dto.MobileInstallationDtos.AdminView> pushKitInstallations() {
        return mobileInstallations.listAllForAdmin();
    }

    @PostMapping("/push-kit/installations/{id}/test")
    @PreAuthorize("hasRole('ADMIN')")
    com.guanlan.monitor.api.dto.MobileInstallationDtos.TestResult testPushKitInstallation(@PathVariable String id) {
        return mobileInstallations.testAsAdmin(id);
    }
}
