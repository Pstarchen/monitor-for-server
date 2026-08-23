package com.guanlan.monitor.service;

import org.springframework.stereotype.Component;

import java.time.Instant;
import java.util.ArrayDeque;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/** Small in-memory guard for the short-lived MCP HTTP endpoint. */
@Component
public class McpRateLimiter {
    private static final int PER_SECOND = 10;
    private static final int PER_MINUTE = 120;
    private static final int MAX_KEYS = 4096;
    private final Map<Long, Window> windows = new ConcurrentHashMap<>();

    public boolean allow(Long tokenId) {
        if (tokenId == null) return false;
        long now = Instant.now().toEpochMilli();
        Window window = windows.computeIfAbsent(tokenId, ignored -> new Window());
        synchronized (window) {
            while (!window.timestamps.isEmpty() && window.timestamps.peekFirst() <= now - 60_000) window.timestamps.removeFirst();
            if (window.timestamps.size() >= PER_MINUTE) return false;
            long secondCutoff = now - 1_000;
            int recent = 0;
            for (Long timestamp : window.timestamps) if (timestamp > secondCutoff) recent++;
            if (recent >= PER_SECOND) return false;
            window.timestamps.addLast(now);
        }
        if (windows.size() > MAX_KEYS) windows.entrySet().removeIf(entry -> {
            synchronized (entry.getValue()) { return entry.getValue().timestamps.isEmpty(); }
        });
        return true;
    }

    private static final class Window {
        private final ArrayDeque<Long> timestamps = new ArrayDeque<>();
    }
}
