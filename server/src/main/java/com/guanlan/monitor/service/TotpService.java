package com.guanlan.monitor.service;

import org.springframework.stereotype.Component;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.net.URLEncoder;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.time.Instant;

/** RFC 6238 TOTP with the interoperable 6-digit SHA-1 profile. */
@Component
public class TotpService {
    private static final char[] BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".toCharArray();
    private static final long PERIOD_SECONDS = 30;
    private static final int DIGITS = 6;
    private final SecureRandom random = new SecureRandom();

    public String generateSecret() {
        byte[] bytes = new byte[20];
        random.nextBytes(bytes);
        return encodeBase32(bytes);
    }

    public boolean verify(String secret, String code, Instant now) {
        if (secret == null || code == null || !code.matches("\\d{" + DIGITS + "}")) return false;
        byte[] decoded;
        try {
            decoded = decodeBase32(secret);
        } catch (IllegalArgumentException exception) {
            return false;
        }
        long counter = Math.floorDiv(now.getEpochSecond(), PERIOD_SECONDS);
        for (long offset = -1; offset <= 1; offset++) {
            String expected = code(decoded, counter + offset);
            if (MessageDigest.isEqual(expected.getBytes(StandardCharsets.US_ASCII), code.getBytes(StandardCharsets.US_ASCII))) {
                return true;
            }
        }
        return false;
    }

    public String currentCode(String secret, Instant now) {
        return code(decodeBase32(secret), Math.floorDiv(now.getEpochSecond(), PERIOD_SECONDS));
    }

    public String otpauthUri(String secret, String issuer, String account) {
        String safeIssuer = issuer == null || issuer.isBlank() ? "Guanlan Monitor" : issuer.trim();
        String safeAccount = account == null || account.isBlank() ? "account" : account.trim();
        String label = urlEncode(safeIssuer) + ":" + urlEncode(safeAccount);
        return "otpauth://totp/" + label + "?secret=" + secret + "&issuer=" + urlEncode(safeIssuer)
                + "&algorithm=SHA1&digits=" + DIGITS + "&period=" + PERIOD_SECONDS;
    }

    private String code(byte[] secret, long counter) {
        try {
            Mac mac = Mac.getInstance("HmacSHA1");
            mac.init(new SecretKeySpec(secret, "HmacSHA1"));
            byte[] hash = mac.doFinal(ByteBuffer.allocate(Long.BYTES).putLong(counter).array());
            int offset = hash[hash.length - 1] & 0x0f;
            int binary = ((hash[offset] & 0x7f) << 24)
                    | ((hash[offset + 1] & 0xff) << 16)
                    | ((hash[offset + 2] & 0xff) << 8)
                    | (hash[offset + 3] & 0xff);
            return "%06d".formatted(binary % 1_000_000);
        } catch (Exception exception) {
            throw new IllegalStateException("Unable to generate TOTP code", exception);
        }
    }

    private String encodeBase32(byte[] bytes) {
        StringBuilder result = new StringBuilder((bytes.length * 8 + 4) / 5);
        int buffer = 0;
        int bits = 0;
        for (byte value : bytes) {
            buffer = (buffer << 8) | (value & 0xff);
            bits += 8;
            while (bits >= 5) {
                bits -= 5;
                result.append(BASE32[(buffer >>> bits) & 31]);
            }
        }
        if (bits > 0) result.append(BASE32[(buffer << (5 - bits)) & 31]);
        return result.toString();
    }

    private byte[] decodeBase32(String value) {
        String normalized = value.replace(" ", "").replace("-", "").toUpperCase(java.util.Locale.ROOT);
        if (normalized.isBlank()) throw new IllegalArgumentException("empty secret");
        byte[] result = new byte[normalized.length() * 5 / 8];
        int buffer = 0;
        int bits = 0;
        int index = 0;
        for (char character : normalized.toCharArray()) {
            int digit = character < 128 ? "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".indexOf(character) : -1;
            if (digit < 0) throw new IllegalArgumentException("invalid secret");
            buffer = (buffer << 5) | digit;
            bits += 5;
            if (bits >= 8) {
                bits -= 8;
                if (index >= result.length) throw new IllegalArgumentException("invalid secret length");
                result[index++] = (byte) ((buffer >>> bits) & 0xff);
            }
        }
        if (index == 0) throw new IllegalArgumentException("invalid secret");
        return result;
    }

    private String urlEncode(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8).replace("+", "%20");
    }
}
