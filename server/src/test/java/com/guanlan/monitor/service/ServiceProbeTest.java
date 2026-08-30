package com.guanlan.monitor.service;

import com.guanlan.monitor.domain.ServiceCheck;
import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

import java.net.InetSocketAddress;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import java.time.Instant;
import java.util.Optional;
import javax.net.ssl.SSLSession;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class ServiceProbeTest {
    private HttpServer server;

    @AfterEach
    void stopServer() {
        if (server != null) server.stop(0);
    }

    @Test
    void httpProbeRecordsSuccessfulStatusAndLatency() throws Exception {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/health", exchange -> {
            exchange.sendResponseHeaders(204, -1);
            exchange.close();
        });
        server.start();

        ServiceCheck check = new ServiceCheck();
        check.setType(ServiceCheck.Type.HTTP_GET);
        check.setTarget("http://127.0.0.1:" + server.getAddress().getPort() + "/health");
        check.setTimeoutMs(2000);

        ServiceProbe.Result result = new ServiceProbe().check(check);

        assertThat(result.success()).isTrue();
        assertThat(result.statusCode()).isEqualTo(204);
        assertThat(result.latencyMs()).isGreaterThanOrEqualTo(0);
        assertThat(result.error()).isNull();
    }

    @Test
    void httpProbeAppliesExpectedStatusAndBodyCondition() throws Exception {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/api/health", exchange -> {
            byte[] body = "{\"status\":\"ok\"}".getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, body.length);
            exchange.getResponseBody().write(body);
            exchange.close();
        });
        server.start();

        ServiceCheck check = new ServiceCheck();
        check.setType(ServiceCheck.Type.HTTP_GET);
        check.setTarget("http://127.0.0.1:" + server.getAddress().getPort() + "/api/health");
        check.setTimeoutMs(2000);
        check.setExpectedStatus(200);
        check.setBodyContains("status\":\"ok");

        ServiceProbe.Result result = new ServiceProbe().check(check);

        assertThat(result.success()).isTrue();
        assertThat(result.statusCode()).isEqualTo(200);
    }

    @Test
    void tcpProbeRejectsMissingPort() {
        ServiceCheck check = new ServiceCheck();
        check.setType(ServiceCheck.Type.TCPING);
        check.setTarget("127.0.0.1");
        check.setTimeoutMs(500);

        ServiceProbe.Result result = new ServiceProbe().check(check);

        assertThat(result.success()).isFalse();
        assertThat(result.error()).contains("host:port");
    }

    @Test
    void tcpProbeAcceptsBracketedHost() throws Exception {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.start();

        ServiceCheck check = new ServiceCheck();
        check.setType(ServiceCheck.Type.TCPING);
        check.setTarget("[127.0.0.1]:" + server.getAddress().getPort());
        check.setTimeoutMs(2000);

        ServiceProbe.Result result = new ServiceProbe().check(check);

        assertThat(result.success()).isTrue();
        assertThat(result.error()).isNull();
    }

    @Test
    void extractsLeafCertificateExpiryFromHttpsResponse() throws Exception {
        HttpResponse<?> response = mock(HttpResponse.class);
        SSLSession session = mock(SSLSession.class);
        X509Certificate certificate = mock(X509Certificate.class);
        Instant expected = Instant.parse("2030-01-02T03:04:05Z");
        when(response.sslSession()).thenReturn(Optional.of(session));
        when(session.getPeerCertificates()).thenReturn(new Certificate[]{certificate});
        when(certificate.getNotAfter()).thenReturn(java.util.Date.from(expected));

        assertThat(ServiceProbe.certificateExpiresAt(response)).isEqualTo(expected);
    }
}
