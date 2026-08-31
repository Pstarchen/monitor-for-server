package com.guanlan.monitor.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.api.dto.DiscoveryDtos;
import com.guanlan.monitor.domain.DiscoveryScan;
import com.guanlan.monitor.repository.DiscoveryResultRepository;
import com.guanlan.monitor.repository.DiscoveryScanRepository;
import com.guanlan.monitor.security.ApiTokenPrincipal;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.scheduling.concurrent.ThreadPoolTaskExecutor;

import java.util.List;
import java.util.Set;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

class NetworkDiscoveryServiceTest {
    private final DiscoveryScanRepository scans = mock(DiscoveryScanRepository.class);
    private final DiscoveryResultRepository results = mock(DiscoveryResultRepository.class);
    private final AuditService audit = mock(AuditService.class);
    private final ThreadPoolTaskExecutor executor = mock(ThreadPoolTaskExecutor.class);
    private final NetworkDiscoveryService service = new NetworkDiscoveryService(scans, results, new ObjectMapper(), audit, executor);

    @Test
    void normalizesPrivateCidrAndSchedulesBoundedScan() {
        org.mockito.Mockito.when(scans.save(any(DiscoveryScan.class))).thenAnswer(invocation -> {
            DiscoveryScan scan = invocation.getArgument(0);
            scan.setId(9L);
            return scan;
        });

        var view = service.start(new DiscoveryDtos.StartRequest("192.168.10.14/24", List.of(443, 80, 443), 200, 8), "admin", session("admin"));

        assertThat(view.id()).isEqualTo(9L);
        assertThat(view.cidr()).isEqualTo("192.168.10.0/24");
        assertThat(view.totalHosts()).isEqualTo(256);
        assertThat(view.ports()).containsExactly(443, 80);
        verify(executor).execute(any(Runnable.class));
    }

    @Test
    void rejectsPublicAndOversizedRanges() {
        assertThatThrownBy(() -> service.start(new DiscoveryDtos.StartRequest("8.8.8.0/24", null, null, null), "admin", session("admin")))
                .isInstanceOf(ApiException.class).hasMessageContaining("RFC1918");
        assertThatThrownBy(() -> service.start(new DiscoveryDtos.StartRequest("192.168.1.0/23", null, null, null), "admin", session("admin")))
                .isInstanceOf(ApiException.class).hasMessageContaining("/24");
    }

    @Test
    void doesNotAllowApiTokensToStartDiscovery() {
        var token = new ApiTokenPrincipal(1L, "token", "ADMIN", Set.of("discovery:*"), Set.of());
        var authentication = new TestingAuthenticationToken(token, "secret", token.getAuthorities());
        assertThatThrownBy(() -> service.start(new DiscoveryDtos.StartRequest("10.0.0.0/24", null, null, null), "token", authentication))
                .isInstanceOf(ApiException.class).hasMessageContaining("API Token");
    }

    private TestingAuthenticationToken session(String username) {
        var user = new org.springframework.security.core.userdetails.User(username, "", List.of());
        return new TestingAuthenticationToken(user, "secret", user.getAuthorities());
    }
}
