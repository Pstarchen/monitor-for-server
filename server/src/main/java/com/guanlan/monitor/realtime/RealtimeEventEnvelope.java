package com.guanlan.monitor.realtime;

import com.fasterxml.jackson.databind.JsonNode;

import java.time.Instant;

public record RealtimeEventEnvelope(
        int schemaVersion,
        String eventId,
        String type,
        Instant occurredAt,
        String controllerId,
        JsonNode payload
) {}
