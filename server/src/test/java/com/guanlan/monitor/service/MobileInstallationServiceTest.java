package com.guanlan.monitor.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.api.dto.MobileInstallationDtos;
import com.guanlan.monitor.config.AppProperties;
import com.guanlan.monitor.domain.MobileInstallation;
import com.guanlan.monitor.domain.UserAccount;
import com.guanlan.monitor.domain.ApiToken;
import com.guanlan.monitor.repository.ApiTokenRepository;
import com.guanlan.monitor.repository.MobilePushDeliveryRepository;
import com.guanlan.monitor.service.DeviceAccessService;
import com.guanlan.monitor.security.ApiTokenPrincipal;
import com.guanlan.monitor.push.PushKitClient;
import com.guanlan.monitor.repository.MobileInstallationRepository;
import com.guanlan.monitor.repository.UserAccountRepository;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.Base64;
import java.util.Optional;
import java.util.List;

import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class MobileInstallationServiceTest {
    @Test
    void encryptsPushTokenAndNeverReturnsItFromInstallationView() {
        MobileInstallationRepository installations = mock(MobileInstallationRepository.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        UserAccount user = new UserAccount();
        user.setId(7L);
        user.setUsername("alice");
        ApiTokenRepository apiTokens = mock(ApiTokenRepository.class);
        MobilePushDeliveryRepository deliveries = mock(MobilePushDeliveryRepository.class);
        DeviceAccessService access = mock(DeviceAccessService.class);
        ApiToken apiToken = new ApiToken();
        apiToken.setId(11L);
        apiToken.setUser(user);
        apiToken.setScopesJson("[\"nezha:push:write\"]");
        apiToken.setServerIdsJson("[]");
        when(users.findByUsernameIgnoreCase("alice")).thenReturn(Optional.of(user));
        when(apiTokens.findByIdAndUserIdAndRevokedAtIsNull(11L, 7L)).thenReturn(Optional.of(apiToken));
        when(installations.findByApiTokenIdAndClientInstallationId(11L, "phone-1")).thenReturn(Optional.empty());
        when(installations.existsByTokenFingerprintAndIdNot(anyString(), anyString())).thenReturn(false);
        when(installations.save(any())).thenAnswer(invocation -> {
            MobileInstallation value = invocation.getArgument(0);
            value.setId("installation-1");
            return value;
        });
        AppProperties properties = new AppProperties();
        properties.setSettingsEncryptionKey(Base64.getEncoder().encodeToString(new byte[32]));
        SecretValueCodec codec = new SecretValueCodec(properties);
        PushKitClient pushKit = mock(PushKitClient.class);
        MobileInstallationService service = new MobileInstallationService(installations, users, apiTokens, deliveries,
                access, codec, pushKit, new ObjectMapper());
        String token = "push-token-0123456789";

        var principal = new ApiTokenPrincipal(11L, "alice", "VIEWER",
                java.util.Set.of("nezha:push:write"), java.util.Set.of());
        var authentication = new UsernamePasswordAuthenticationToken(principal, "", principal.getAuthorities());
        MobileInstallationDtos.View view = service.create(authentication, new MobileInstallationDtos.CreateRequest(
                "phone-1", MobileInstallation.Platform.HARMONYOS, token, "1.0.0", "test-device"));

        ArgumentCaptor<MobileInstallation> captured = ArgumentCaptor.forClass(MobileInstallation.class);
        verify(installations).save(captured.capture());
        assertThat(captured.getValue().getTokenCiphertext()).startsWith("v1:").doesNotContain(token);
        assertThat(codec.decrypt(captured.getValue().getTokenCiphertext())).isEqualTo(token);
        assertThat(view.tokenSuffix()).isEqualTo("23456789");
        assertThat(view.toString()).doesNotContain(token);
    }
}
