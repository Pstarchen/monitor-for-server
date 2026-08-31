package com.guanlan.monitor.service;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.api.dto.DeviceStatusDtos;
import com.guanlan.monitor.domain.Device;
import com.guanlan.monitor.domain.DeviceStatusEvent;
import com.guanlan.monitor.repository.DeviceRepository;
import com.guanlan.monitor.repository.DeviceStatusEventRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.PageRequest;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Duration;
import java.time.Instant;
import java.util.List;

@Service
@RequiredArgsConstructor
public class DeviceStatusHistoryService {
    private final DeviceStatusEventRepository events;
    private final DeviceRepository devices;

    @Transactional
    public void record(Device device, Device.Status previous, Device.Status status, String reason) {
        if (device == null || status == null || status == previous) return;
        DeviceStatusEvent event = new DeviceStatusEvent();
        event.setDevice(device);
        event.setPreviousStatus(previous);
        event.setStatus(status);
        event.setReason(reason == null || reason.isBlank() ? "设备状态发生变化" : reason.trim());
        events.save(event);
    }

    @Transactional(readOnly = true)
    public List<DeviceStatusDtos.View> list(String deviceId, Instant from, Instant to, int limit) {
        devices.findById(deviceId).orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "设备不存在"));
        Instant end = to == null ? Instant.now() : to;
        Instant start = from == null ? end.minus(Duration.ofDays(31)) : from;
        if (start.isAfter(end) || Duration.between(start, end).toDays() > 366) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "状态历史时间范围无效或超过 366 天");
        }
        return events.findByDeviceIdAndChangedAtBetweenOrderByChangedAtDesc(deviceId, start, end, PageRequest.of(0, Math.min(Math.max(limit, 1), 500))).stream()
                .map(event -> new DeviceStatusDtos.View(event.getId(), event.getPreviousStatus(), event.getStatus(), event.getReason(), event.getChangedAt()))
                .toList();
    }

    @Transactional
    public long removeBefore(Instant cutoff) { return events.deleteByChangedAtBefore(cutoff); }
}
