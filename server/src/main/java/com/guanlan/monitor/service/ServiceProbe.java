package com.guanlan.monitor.service;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.domain.ServiceCheck;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.*;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.time.Instant;
import java.util.Optional;

@Component
public class ServiceProbe {
    public Result check(ServiceCheck check) {
        return check(check, "");
    }

    public Result check(ServiceCheck check, String credential) {
        long started = System.nanoTime();
        try {
            Result result = switch (check.getType()) {
                case HTTP_GET -> http(check);
                case ICMP_PING -> ping(check);
                case TCPING -> tcp(check);
                case FTP -> ftp(check);
                case SFTP -> sftp(check);
                case SNMP -> snmp(check, credential);
                case REDIS_PING -> redis(check);
                case POSTGRESQL -> postgres(check);
                case MYSQL -> mysql(check);
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

    private Result ftp(ServiceCheck check) throws IOException {
        HostPort hostPort = parseHostPort(check.getTarget());
        try (Socket socket = connect(hostPort, check.getTimeoutMs())) {
            String greeting = readLine(socket.getInputStream(), 4096);
            boolean success = greeting.startsWith("220");
            if (success) {
                socket.getOutputStream().write("QUIT\r\n".getBytes(StandardCharsets.US_ASCII));
                socket.getOutputStream().flush();
            }
            return new Result(success, 0, null, success ? null : "FTP 未返回 220 欢迎响应", null);
        }
    }

    private Result sftp(ServiceCheck check) throws IOException {
        HostPort hostPort = parseHostPort(check.getTarget());
        try (Socket socket = connect(hostPort, check.getTimeoutMs())) {
            String banner = readLine(socket.getInputStream(), 255);
            boolean success = banner.startsWith("SSH-");
            return new Result(success, 0, null, success ? null : "SFTP 未返回 SSH 协议头", null);
        }
    }

    private Result snmp(ServiceCheck check, String community) throws IOException {
        HostPort hostPort = parseHostPort(check.getTarget());
        String value = community == null || community.isBlank() ? "public" : community.trim();
        if (value.length() > 255) throw new IOException("SNMP community 过长");
        byte[] request = snmpGetRequest(value, 1, "1.3.6.1.2.1.1.1.0");
        try (DatagramSocket socket = new DatagramSocket()) {
            socket.setSoTimeout(check.getTimeoutMs());
            socket.send(new DatagramPacket(request, request.length, InetAddress.getByName(hostPort.host()), hostPort.port()));
            byte[] buffer = new byte[65535];
            DatagramPacket response = new DatagramPacket(buffer, buffer.length);
            socket.receive(response);
            byte[] payload = java.util.Arrays.copyOf(response.getData(), response.getLength());
            if (!hasBerTag(payload, 0xA2, 0)) return new Result(false, 0, null, "SNMP 未返回 GetResponse", null);
            return new Result(true, 0, null, null, null);
        }
    }

    private byte[] snmpGetRequest(String community, int requestId, String oid) {
        byte[] version = berTlv(0x02, new byte[]{0x01});
        byte[] communityValue = berTlv(0x04, community.getBytes(StandardCharsets.US_ASCII));
        byte[] request = berTlv(0x02, integerBytes(requestId));
        byte[] errorStatus = berTlv(0x02, new byte[]{0x00});
        byte[] errorIndex = berTlv(0x02, new byte[]{0x00});
        byte[] objectId = berTlv(0x06, oidBytes(oid));
        byte[] nullValue = berTlv(0x05, new byte[0]);
        byte[] variable = berTlv(0x30, concat(objectId, nullValue));
        byte[] variableList = berTlv(0x30, variable);
        byte[] pdu = berTlv(0xA0, concat(request, errorStatus, errorIndex, variableList));
        return berTlv(0x30, concat(version, communityValue, pdu));
    }

    private boolean hasBerTag(byte[] bytes, int wanted, int depth) {
        if (depth > 12) return false;
        int offset = 0;
        while (offset + 2 <= bytes.length) {
            int tag = bytes[offset++] & 0xff;
            int lengthByte = bytes[offset++] & 0xff;
            int length;
            if ((lengthByte & 0x80) == 0) {
                length = lengthByte;
            } else {
                int count = lengthByte & 0x7f;
                if (count == 0 || count > 4 || offset + count > bytes.length) return false;
                length = 0;
                for (int i = 0; i < count; i++) length = (length << 8) | (bytes[offset++] & 0xff);
            }
            if (length < 0 || offset + length > bytes.length) return false;
            if (tag == wanted || ((tag & 0x20) != 0 && hasBerTag(java.util.Arrays.copyOfRange(bytes, offset, offset + length), wanted, depth + 1))) return true;
            offset += length;
        }
        return false;
    }

    private byte[] berTlv(int tag, byte[] value) {
        return concat(new byte[]{(byte) tag}, berLength(value.length), value);
    }

    private byte[] berLength(int length) {
        if (length < 128) return new byte[]{(byte) length};
        int bytes = 0;
        int value = length;
        while (value > 0) { bytes++; value >>= 8; }
        byte[] result = new byte[bytes + 1];
        result[0] = (byte) (0x80 | bytes);
        for (int i = bytes; i > 0; i--) { result[i] = (byte) (length & 0xff); length >>= 8; }
        return result;
    }

    private byte[] integerBytes(int value) {
        if (value == 0) return new byte[]{0};
        byte[] result = new byte[4];
        int index = result.length;
        while (value != 0) { result[--index] = (byte) value; value >>= 8; }
        if ((result[index] & 0x80) != 0) result[--index] = 0;
        return java.util.Arrays.copyOfRange(result, index, result.length);
    }

    private byte[] oidBytes(String oid) {
        String[] parts = oid.split("\\.");
        int first = Integer.parseInt(parts[0]) * 40 + Integer.parseInt(parts[1]);
        java.io.ByteArrayOutputStream output = new java.io.ByteArrayOutputStream();
        output.write(first);
        for (int i = 2; i < parts.length; i++) {
            int value = Integer.parseInt(parts[i]);
            byte[] encoded = new byte[5];
            int index = encoded.length - 1;
            encoded[index] = (byte) (value & 0x7f);
            while ((value >>= 7) > 0) encoded[--index] = (byte) ((value & 0x7f) | 0x80);
            output.write(encoded, index, encoded.length - index);
        }
        return output.toByteArray();
    }

    private byte[] concat(byte[]... values) {
        int length = 0;
        for (byte[] value : values) length += value.length;
        byte[] result = new byte[length];
        int offset = 0;
        for (byte[] value : values) { System.arraycopy(value, 0, result, offset, value.length); offset += value.length; }
        return result;
    }

    private Result redis(ServiceCheck check) throws IOException {
        HostPort hostPort = parseHostPort(check.getTarget());
        try (Socket socket = connect(hostPort, check.getTimeoutMs())) {
            OutputStream output = socket.getOutputStream();
            output.write("*1\r\n$4\r\nPING\r\n".getBytes(StandardCharsets.US_ASCII));
            output.flush();
            String response = readLine(socket.getInputStream(), 1024);
            if (response.startsWith("+PONG") || response.startsWith("-NOAUTH") || response.startsWith("-NOPERM")) {
                return new Result(true, 0, null, null, null);
            }
            return new Result(false, 0, null, "Redis 未返回有效 PING 响应", null);
        }
    }

    private Result postgres(ServiceCheck check) throws IOException {
        HostPort hostPort = parseHostPort(check.getTarget());
        try (Socket socket = connect(hostPort, check.getTimeoutMs())) {
            byte[] user = "monitor".getBytes(StandardCharsets.US_ASCII);
            byte[] database = "postgres".getBytes(StandardCharsets.US_ASCII);
            byte[] application = "guanlan-monitor".getBytes(StandardCharsets.US_ASCII);
            byte[] userKey = "user\0".getBytes(StandardCharsets.US_ASCII);
            byte[] databaseKey = "database\0".getBytes(StandardCharsets.US_ASCII);
            byte[] applicationKey = "application_name\0".getBytes(StandardCharsets.US_ASCII);
            int payloadLength = 4 + userKey.length + user.length + 1 + databaseKey.length + database.length + 1
                    + applicationKey.length + application.length + 1;
            java.io.DataOutputStream output = new java.io.DataOutputStream(socket.getOutputStream());
            output.writeInt(4 + payloadLength);
            output.writeInt(196608); // PostgreSQL protocol 3.0
            output.write(userKey);
            output.write(user);
            output.writeByte(0);
            output.write(databaseKey);
            output.write(database);
            output.writeByte(0);
            output.write(applicationKey);
            output.write(application);
            output.writeByte(0);
            output.flush();

            InputStream input = socket.getInputStream();
            int messageType = input.read();
            if (messageType < 0) throw new IOException("PostgreSQL 未返回握手响应");
            int length = readInt(input);
            if (length < 4 || length > 1_048_576) throw new IOException("PostgreSQL 握手响应无效");
            skipFully(input, length - 4);
            if (messageType != 'R' && messageType != 'E' && messageType != 'N') {
                throw new IOException("PostgreSQL 未返回有效协议响应");
            }
            return new Result(true, 0, null, null, null);
        }
    }

    private Result mysql(ServiceCheck check) throws IOException {
        HostPort hostPort = parseHostPort(check.getTarget());
        try (Socket socket = connect(hostPort, check.getTimeoutMs())) {
            InputStream input = socket.getInputStream();
            byte[] header = readFully(input, 4);
            int payloadLength = (header[0] & 0xff) | ((header[1] & 0xff) << 8) | ((header[2] & 0xff) << 16);
            if (payloadLength < 1 || payloadLength > 1_048_576) throw new IOException("MySQL 握手响应无效");
            byte[] payload = readFully(input, payloadLength);
            if ((payload[0] & 0xff) != 0x0a) throw new IOException("未识别到 MySQL 握手协议");
            return new Result(true, 0, null, null, null);
        }
    }

    private Socket connect(HostPort hostPort, int timeoutMs) throws IOException {
        Socket socket = new Socket();
        try {
            socket.connect(new InetSocketAddress(hostPort.host(), hostPort.port()), timeoutMs);
            socket.setSoTimeout(timeoutMs);
            return socket;
        } catch (IOException exception) {
            socket.close();
            throw exception;
        }
    }

    private String readLine(InputStream input, int maxBytes) throws IOException {
        byte[] buffer = new byte[maxBytes];
        int index = 0;
        while (index < buffer.length) {
            int value = input.read();
            if (value < 0 || value == '\n') break;
            if (value != '\r') buffer[index++] = (byte) value;
        }
        if (index == buffer.length) throw new IOException("Redis 响应过长");
        return new String(buffer, 0, index, StandardCharsets.US_ASCII);
    }

    private int readInt(InputStream input) throws IOException {
        int first = input.read();
        int second = input.read();
        int third = input.read();
        int fourth = input.read();
        if (first < 0 || second < 0 || third < 0 || fourth < 0) throw new IOException("协议响应不完整");
        return (first << 24) | (second << 16) | (third << 8) | fourth;
    }

    private void skipFully(InputStream input, int count) throws IOException {
        while (count > 0) {
            long skipped = input.skip(count);
            if (skipped > 0) {
                count -= (int) skipped;
                continue;
            }
            if (input.read() < 0) throw new IOException("协议响应不完整");
            count--;
        }
    }

    private byte[] readFully(InputStream input, int length) throws IOException {
        byte[] bytes = input.readNBytes(length);
        if (bytes.length != length) throw new IOException("协议响应不完整");
        return bytes;
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
