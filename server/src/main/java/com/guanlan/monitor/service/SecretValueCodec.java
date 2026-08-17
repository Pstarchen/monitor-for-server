package com.guanlan.monitor.service;

import com.guanlan.monitor.config.AppProperties;
import org.springframework.stereotype.Component;

import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.util.Base64;

@Component
public class SecretValueCodec {
    private static final String PREFIX = "v1:";
    private static final int NONCE_BYTES = 12;
    private final SecretKeySpec key;
    private final SecureRandom random = new SecureRandom();

    public SecretValueCodec(AppProperties properties) {
        String configured = properties.getSettingsEncryptionKey();
        if (configured == null || configured.isBlank()) {
            key = null;
            return;
        }
        try {
            byte[] raw = Base64.getDecoder().decode(configured.trim());
            if (raw.length != 32) {
                throw new IllegalArgumentException("SETTINGS_ENCRYPTION_KEY must decode to 32 bytes");
            }
            key = new SecretKeySpec(raw, "AES");
        } catch (IllegalArgumentException exception) {
            throw new IllegalStateException("SETTINGS_ENCRYPTION_KEY must be a Base64-encoded 32-byte key", exception);
        }
    }

    public boolean available() {
        return key != null;
    }

    public String encrypt(String value) {
        requireKey();
        byte[] nonce = new byte[NONCE_BYTES];
        random.nextBytes(nonce);
        try {
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.ENCRYPT_MODE, key, new GCMParameterSpec(128, nonce));
            byte[] encrypted = cipher.doFinal(value.getBytes(StandardCharsets.UTF_8));
            return PREFIX + Base64.getEncoder().encodeToString(
                    ByteBuffer.allocate(nonce.length + encrypted.length).put(nonce).put(encrypted).array());
        } catch (GeneralSecurityException exception) {
            throw new IllegalStateException("Unable to encrypt setting", exception);
        }
    }

    public String decrypt(String value) {
        requireKey();
        if (value == null || !value.startsWith(PREFIX)) {
            throw new IllegalStateException("Encrypted setting has an unsupported format");
        }
        try {
            byte[] payload = Base64.getDecoder().decode(value.substring(PREFIX.length()));
            if (payload.length <= NONCE_BYTES) {
                throw new GeneralSecurityException("Encrypted setting is truncated");
            }
            byte[] nonce = new byte[NONCE_BYTES];
            byte[] encrypted = new byte[payload.length - NONCE_BYTES];
            System.arraycopy(payload, 0, nonce, 0, nonce.length);
            System.arraycopy(payload, nonce.length, encrypted, 0, encrypted.length);
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(128, nonce));
            return new String(cipher.doFinal(encrypted), StandardCharsets.UTF_8);
        } catch (GeneralSecurityException | IllegalArgumentException exception) {
            throw new IllegalStateException("Unable to decrypt setting", exception);
        }
    }

    private void requireKey() {
        if (key == null) {
            throw new IllegalStateException("SETTINGS_ENCRYPTION_KEY is not configured");
        }
    }
}
