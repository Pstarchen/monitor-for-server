package com.guanlan.monitor.realtime;

record RealtimeTransportMessage(long sequence, String deviceId, RealtimeEventEnvelope event) {}
