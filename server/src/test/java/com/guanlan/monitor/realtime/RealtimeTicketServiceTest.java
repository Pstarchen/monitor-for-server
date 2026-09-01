package com.guanlan.monitor.realtime;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.config.AppProperties;
import com.guanlan.monitor.config.RealtimeProperties;
import org.junit.jupiter.api.Test;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class RealtimeTicketServiceTest {
    @Test
    void issuesShortLivedSingleUseTicketWithoutExposingSessionCredentials() {
        AppProperties app = new AppProperties();
        app.setRedisEnabled(false);
        RealtimeProperties properties = new RealtimeProperties();
        RealtimeOutboxService outbox = mock(RealtimeOutboxService.class);
        when(outbox.latestEventId()).thenReturn("11111111-1111-1111-1111-111111111111");
        var authentication = new UsernamePasswordAuthenticationToken("alice", "session-secret",
                List.of(new SimpleGrantedAuthority("ROLE_VIEWER")));
        RealtimeTicketService service = new RealtimeTicketService(mock(StringRedisTemplate.class),
                new ObjectMapper(), app, properties, outbox);

        RealtimeTicketService.IssuedTicket issued = service.issue(authentication, null);
        RealtimeTicketService.ConsumedTicket consumed = service.consume(issued.ticket());

        assertThat(consumed.authentication().getName()).isEqualTo("alice");
        assertThat(consumed.afterEventId()).isEqualTo("11111111-1111-1111-1111-111111111111");
        assertThat(issued.ticket()).doesNotContain("session-secret", "alice");
        assertThatThrownBy(() -> service.consume(issued.ticket())).isInstanceOf(ApiException.class);
    }
}
