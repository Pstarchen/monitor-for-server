package com.guanlan.monitor.realtime;

import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

@Component
@RequiredArgsConstructor
public class RealtimeRedisSubscriber {
    private final RealtimeEventDispatcher dispatcher;

    public void receive(String message) {
        dispatcher.dispatch(message);
    }
}
