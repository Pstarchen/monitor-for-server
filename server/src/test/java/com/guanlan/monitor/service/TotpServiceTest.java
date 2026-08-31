package com.guanlan.monitor.service;

import org.junit.jupiter.api.Test;

import java.time.Instant;

import static org.assertj.core.api.Assertions.assertThat;

class TotpServiceTest {
    private final TotpService totp = new TotpService();

    @Test
    void followsRfc6238Sha1Vectors() {
        String secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";

        assertThat(totp.currentCode(secret, Instant.ofEpochSecond(59))).isEqualTo("287082");
        assertThat(totp.currentCode(secret, Instant.ofEpochSecond(1_111_111_109))).isEqualTo("081804");
        assertThat(totp.currentCode(secret, Instant.ofEpochSecond(2_000_000_000))).isEqualTo("279037");
    }

    @Test
    void verifiesOnlySixDigitCodesWithinOneTimeWindow() {
        String secret = totp.generateSecret();
        Instant now = Instant.ofEpochSecond(1_700_000_000);
        String code = totp.currentCode(secret, now);

        assertThat(totp.verify(secret, code, now)).isTrue();
        assertThat(totp.verify(secret, code, now.plusSeconds(30))).isTrue();
        assertThat(totp.verify(secret, code, now.plusSeconds(91))).isFalse();
        assertThat(totp.verify(secret, "12345", now)).isFalse();
    }
}
