package com.guanlan.monitor.service;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.domain.ServiceCheck;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.io.InputStream;
import java.net.*;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.time.Instant;
import java.util.Optional;

@Component
public class ServiceProbe {
    public Result check(ServiceCheck check) {
        long started = System.nanoTime();
        try {
            Result result = switch (check.getType()) {
                case HTTP_GET -> http(check);
                case ICMP_PING -> ping(check);
                case TCPING -> tcp(check);
                case HEARTBEAT -> throw new ApiException(HttpStatus.BAD_REQUEST, "心跳监控由外部任务上报，不能主动探测");
            };
            return result.latencyMs() > 0 ? result : new Result(result.success(), elapsed(started), result.statusCode(), result.error(), result.certificateExpiresAt());
        } catch (Exception exception) {
            return new Result(false, elapsed(started), null, message(exception), null);
        }
    }

    private Result http(ServiceCheck check) throws IOException, InterruptedException {
        URI uri;
        try {
            uri = URI.create(check.getTarget().trim());
        } catch (IllegalArgumentException exception) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "HTTP 目标地址无效");
        }
        if (!"http".equalsIgnoreCase(uri.getScheme()) && !"https".equalsIgnoreCase(uri.getScheme())) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "HTTP 目标必须使用 http 或 https");
        }
        HttpClient client = HttpClient.newBuilder()
                .connectTimeout(Duration.ofMillis(check.getTimeoutMs()))
                .followRedirects(HttpClient.Redirect.NORMAL)
                .build();
        HttpRequest request = HttpRequest.newBuilder(uri)
                .timeout(Duration.ofMillis(check.getTimeoutMs()))
                .header("User-Agent", "Guanlan-Monitor-ServiceProbe/1.0")
                .GET()
                .build();
        HttpResponse<InputStream> response = client.send(request, HttpResponse.BodyHandlers.ofInputStream());
        int status = response.statusCode();
        String body;
        try (InputStream stream = response.body()) {
            body = new String(stream.readNBytes(64 * 1024), java.nio.charset.StandardCharsets.UTF_8);
        }
        boolean statusOk = check.getExpectedStatus() == null
                ? status >= 200 && status < 400
                : status == check.getExpectedStatus();
        boolean bodyOk = check.getBodyContains() == null || check.getBodyContains().isBlank()
                || body.contains(check.getBodyContains());
        String error = !statusOk ? "HTTP 状态码 " + status + "（期望 " + (check.getExpectedStatus() == null ? "2xx/3xx" : check.getExpectedStatus()) + "）"
                : !bodyOk ? "响应体未包含期望文本" : null;
        return new Result(statusOk && bodyOk, 0, status, error, certificateExpiresAt(response));
    }

    private Result ping(ServiceCheck check) throws IOException {
        InetAddress address = InetAddress.getByName(check.getTarget().trim());
        boolean reachable = address.isReachable(check.getTimeoutMs());
        return new Result(reachable, 0, null, reachable ? null : "目标不可达", null);
    }

    private Result tcp(ServiceCheck check) throws IOException {
        HostPort hostPort = parseHostPort(check.getTarget());
        try (Socket socket = new Socket()) {
            socket.connect(new InetSocketAddress(hostPort.host(), hostPort.port()), check.getTimeoutMs());
            return new Result(true, 0, null, null, null);
        }
    }

    private HostPort parseHostPort(String value) {
        String target = value.trim();
        int separator = target.lastIndexOf(':');
        if (separator <= 0 || separator == target.length() - 1) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "TCP 目标必须是 host:port");
        }
        String host = target.substring(0, separator).trim();
        if (host.startsWith("[") || host.endsWith("]")) {
            if (!(host.startsWith("[") && host.endsWith("]")) || host.length() <= 2) {
                throw new ApiException(HttpStatus.BAD_REQUEST, "TCP 主机地址无效");
            }
            host = host.substring(1, host.length() - 1);
        }
        int port;
        try {
            port = Integer.parseInt(target.substring(separator + 1));
        } catch (NumberFormatException exception) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "TCP 端口无效");
        }
        if (host.isBlank() || port < 1 || port > 65535) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "TCP 目标或端口无效");
        }
        return new HostPort(host, port);
    }

    private long elapsed(long started) {
        return Math.max(0, Math.round((System.nanoTime() - started) / 1_000_000d));
    }

    private String message(Exception exception) {
        String value = exception.getMessage();
        return value == null || value.isBlank() ? exception.getClass().getSimpleName() : value.substring(0, Math.min(300, value.length()));
    }

    static Instant certificateExpiresAt(HttpResponse<?> response) {
        Optional<Instant> expiry = response.sslSession().flatMap(session -> {
            try {
                for (java.security.cert.Certificate certificate : session.getPeerCertificates()) {
                    if (certificate instanceof X509Certificate x509) return Optional.of(x509.getNotAfter().toInstant());
                }
            } catch (Exception ignored) {
                // The HTTP result remains useful even when the provider does not expose its peer chain.
            }
            return Optional.empty();
        });
        return expiry.orElse(null);
    }

    public record Result(boolean success, long latencyMs, Integer statusCode, String error, Instant certificateExpiresAt) {}
    private record HostPort(String host, int port) {}
}
