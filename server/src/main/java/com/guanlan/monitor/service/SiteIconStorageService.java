package com.guanlan.monitor.service;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.config.AppProperties;
import lombok.RequiredArgsConstructor;
import org.springframework.core.io.FileSystemResource;
import org.springframework.core.io.Resource;
import org.springframework.http.HttpStatus;
import org.springframework.http.InvalidMediaTypeException;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Service;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.Locale;
import java.util.Optional;

@Service
@RequiredArgsConstructor
public class SiteIconStorageService {
    public static final long MAX_BYTES = 50L * 1024L * 1024L;

    private static final String ICON_FILE = "site-icon.bin";
    private static final String CONTENT_TYPE_FILE = "site-icon.type";

    private final AppProperties properties;

    public synchronized StoredIcon store(MultipartFile file) {
        if (file == null || file.isEmpty()) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "请选择要上传的网站图标");
        }
        if (file.getSize() > MAX_BYTES) {
            throw new ApiException(HttpStatus.PAYLOAD_TOO_LARGE, "网站图标不能超过 50MB");
        }
        String contentType = file.getContentType() == null ? "" : file.getContentType().trim().toLowerCase(Locale.ROOT);
        if (!isImageContentType(contentType)) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "网站图标必须是图片文件");
        }

        Path directory = storageDirectory();
        Path temporaryIcon = directory.resolve(ICON_FILE + ".tmp");
        Path temporaryType = directory.resolve(CONTENT_TYPE_FILE + ".tmp");
        try {
            Files.createDirectories(directory);
            try (InputStream input = file.getInputStream()) {
                Files.copy(input, temporaryIcon, StandardCopyOption.REPLACE_EXISTING);
            }
            Files.writeString(temporaryType, contentType);
            moveIntoPlace(temporaryIcon, directory.resolve(ICON_FILE));
            moveIntoPlace(temporaryType, directory.resolve(CONTENT_TYPE_FILE));
            return read().orElseThrow(() -> new IOException("stored icon is unavailable"));
        } catch (IOException exception) {
            deleteQuietly(temporaryIcon);
            deleteQuietly(temporaryType);
            throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "网站图标保存失败");
        }
    }

    public synchronized Optional<StoredIcon> read() {
        Path directory = storageDirectory();
        Path icon = directory.resolve(ICON_FILE);
        Path type = directory.resolve(CONTENT_TYPE_FILE);
        if (!Files.isRegularFile(icon) || !Files.isRegularFile(type)) return Optional.empty();
        try {
            String contentType = Files.readString(type).trim().toLowerCase(Locale.ROOT);
            if (!isImageContentType(contentType)) return Optional.empty();
            return Optional.of(new StoredIcon(new FileSystemResource(icon), contentType));
        } catch (IOException exception) {
            return Optional.empty();
        }
    }

    public synchronized void clear() {
        deleteQuietly(storageDirectory().resolve(ICON_FILE));
        deleteQuietly(storageDirectory().resolve(CONTENT_TYPE_FILE));
    }

    private Path storageDirectory() {
        return Path.of(properties.getSiteIconStoragePath()).toAbsolutePath().normalize();
    }

    private void moveIntoPlace(Path source, Path target) throws IOException {
        try {
            Files.move(source, target, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        } catch (AtomicMoveNotSupportedException exception) {
            Files.move(source, target, StandardCopyOption.REPLACE_EXISTING);
        }
    }

    private void deleteQuietly(Path path) {
        try { Files.deleteIfExists(path); } catch (IOException ignored) { }
    }

    private boolean isImageContentType(String contentType) {
        try {
            MediaType mediaType = MediaType.parseMediaType(contentType);
            return "image".equalsIgnoreCase(mediaType.getType()) && !mediaType.isWildcardSubtype();
        } catch (InvalidMediaTypeException exception) {
            return false;
        }
    }

    public record StoredIcon(Resource resource, String contentType) {}
}
