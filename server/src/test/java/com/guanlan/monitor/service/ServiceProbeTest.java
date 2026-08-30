package com.guanlan.monitor.service;

import com.guanlan.monitor.domain.ServiceCheck;
import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.http.HttpResponse;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import java.time.Instant;
import java.util.Optional;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
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
    void redisProbeAcceptsPongResponse() throws Exception {
        try (ProtocolServer redis = protocolServer(socket -> {
            byte[] request = socket.getInputStream().readNBytes(14);
            assertThat(new String(request, StandardCharsets.US_ASCII)).isEqualTo("*1\r\n$4\r\nPING\r\n");
            socket.getOutputStream().write("+PONG\r\n".getBytes(StandardCharsets.US_ASCII));
            socket.getOutputStream().flush();
        })) {
            ServiceCheck check = protocolCheck(ServiceCheck.Type.REDIS_PING, redis.port());

            ServiceProbe.Result result = new ServiceProbe().check(check);

            assertThat(result.success()).isTrue();
            assertThat(result.error()).isNull();
            redis.await();
        }
    }

    @Test
    void postgresProbeAcceptsProtocolAuthenticationResponse() throws Exception {
        try (ProtocolServer postgres = protocolServer(socket -> {
            DataInputStream input = new DataInputStream(socket.getInputStream());
            int length = input.readInt();
            input.skipNBytes(length - 4L);
            DataOutputStream output = new DataOutputStream(socket.getOutputStream());
            output.writeByte('R');
            output.writeInt(8);
            output.writeInt(0);
            output.flush();
        })) {
            ServiceCheck check = protocolCheck(ServiceCheck.Type.POSTGRESQL, postgres.port());

            ServiceProbe.Result result = new ServiceProbe().check(check);

            assertThat(result.success()).isTrue();
            assertThat(result.error()).isNull();
            postgres.await();
        }
    }

    @Test
    void mysqlProbeAcceptsHandshakePacket() throws Exception {
        try (ProtocolServer mysql = protocolServer(socket -> {
            socket.getOutputStream().write(new byte[]{0x04, 0x00, 0x00, 0x00, 0x0a, '8', '.', '0'});
            socket.getOutputStream().flush();
        })) {
            ServiceCheck check = protocolCheck(ServiceCheck.Type.MYSQL, mysql.port());

            ServiceProbe.Result result = new ServiceProbe().check(check);

            assertThat(result.success()).isTrue();
            assertThat(result.error()).isNull();
            mysql.await();
        }
    }

    private ServiceCheck protocolCheck(ServiceCheck.Type type, int port) {
        ServiceCheck check = new ServiceCheck();
        check.setType(type);
        check.setTarget("127.0.0.1:" + port);
        check.setTimeoutMs(2000);
        return check;
    }

    private ProtocolServer protocolServer(ProtocolHandler handler) throws IOException {
        ServerSocket listener = new ServerSocket(0);
        ExecutorService executor = Executors.newSingleThreadExecutor();
        Future<?> future = executor.submit(() -> {
            try (Socket socket = listener.accept()) {
                handler.handle(socket);
            } catch (Exception exception) {
                throw new RuntimeException(exception);
            }
        });
        return new ProtocolServer(listener, executor, future);
    }

    @FunctionalInterface
    private interface ProtocolHandler {
        void handle(Socket socket) throws Exception;
    }

    private record ProtocolServer(ServerSocket listener, ExecutorService executor, Future<?> future) implements AutoCloseable {
        int port() { return listener.getLocalPort(); }

        void await() throws Exception {
            try {
                future.get(2, TimeUnit.SECONDS);
            } catch (ExecutionException exception) {
                if (exception.getCause() instanceof RuntimeException runtime && runtime.getCause() != null) {
                    throw new AssertionError(runtime.getCause());
                }
                throw exception;
            }
        }

        @Override
        public void close() throws IOException {
            listener.close();
            executor.shutdownNow();
        }
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
