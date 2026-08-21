package com.guanlan.monitor.service;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.config.AppProperties;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.http.HttpStatus;
import org.springframework.mock.web.MockMultipartFile;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class SiteIconStorageServiceTest {
    @TempDir
    Path storage;

    private SiteIconStorageService service;

    @BeforeEach
    void setUp() {
        AppProperties properties = new AppProperties();
        properties.setSiteIconStoragePath(storage.toString());
        service = new SiteIconStorageService(properties);
    }

    @AfterEach
    void clearStorage() {
        service.clear();
    }

    @Test
    void storesReadsAndClearsImage() throws IOException {
        byte[] content = "icon-content".getBytes(StandardCharsets.UTF_8);

        service.store(new MockMultipartFile("file", "icon.png", "image/png", content));

        SiteIconStorageService.StoredIcon icon = service.read().orElseThrow();
        assertThat(icon.contentType()).isEqualTo("image/png");
        assertThat(icon.resource().getInputStream().readAllBytes()).isEqualTo(content);
        assertThat(Files.exists(storage.resolve("site-icon.bin"))).isTrue();

        service.clear();

        assertThat(service.read()).isEmpty();
        assertThat(Files.exists(storage.resolve("site-icon.bin"))).isFalse();
        assertThat(Files.exists(storage.resolve("site-icon.type"))).isFalse();
    }

    @Test
    void rejectsNonImageMimeType() {
        assertThatThrownBy(() -> service.store(new MockMultipartFile("file", "icon.txt", "text/plain", "text".getBytes(StandardCharsets.UTF_8))))
                .isInstanceOfSatisfying(ApiException.class, exception -> {
                    assertThat(exception.getStatus()).isEqualTo(HttpStatus.BAD_REQUEST);
                    assertThat(exception.getMessage()).contains("图片");
                });
    }

    @Test
    void rejectsFilesOverTheLimit() {
        byte[] content = new byte[(int) SiteIconStorageService.MAX_BYTES + 1];

        assertThatThrownBy(() -> service.store(new MockMultipartFile("file", "large.png", "image/png", content)))
                .isInstanceOfSatisfying(ApiException.class, exception -> {
                    assertThat(exception.getStatus()).isEqualTo(HttpStatus.PAYLOAD_TOO_LARGE);
                    assertThat(exception.getMessage()).contains("50MB");
                });
    }
}
