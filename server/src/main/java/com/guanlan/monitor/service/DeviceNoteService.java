package com.guanlan.monitor.service;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.api.dto.DeviceNoteDtos;
import com.guanlan.monitor.domain.DeviceNote;
import com.guanlan.monitor.repository.DeviceNoteRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.PageRequest;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Service
@RequiredArgsConstructor
public class DeviceNoteService {
    private final DeviceNoteRepository notes;
    private final DeviceService devices;
    private final AuditService audit;

    @Transactional(readOnly = true)
    public List<DeviceNoteDtos.View> list(String deviceId, int limit) {
        devices.require(deviceId);
        return notes.findByDeviceIdOrderByCreatedAtDesc(deviceId, PageRequest.of(0, bounded(limit))).stream()
                .map(this::view).toList();
    }

    @Transactional(readOnly = true)
    public List<DeviceNoteDtos.View> recent(int limit) {
        return notes.findAllByOrderByCreatedAtDesc(PageRequest.of(0, bounded(limit))).stream()
                .map(this::view).toList();
    }

    @Transactional
    public DeviceNoteDtos.View create(String deviceId, DeviceNoteDtos.CreateRequest request) {
        var device = devices.require(deviceId);
        String content = request.content() == null ? "" : request.content().trim();
        if (content.isBlank()) throw new ApiException(HttpStatus.BAD_REQUEST, "工作记录不能为空");
        DeviceNote note = new DeviceNote();
        note.setDevice(device);
        note.setAuthor(actor());
        note.setContent(content);
        notes.save(note);
        audit.record("DEVICE_NOTE_CREATE", "device:" + deviceId, "新增设备工作记录");
        return view(note);
    }

    @Transactional
    public void delete(String deviceId, Long id) {
        DeviceNote note = notes.findById(id).orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "工作记录不存在"));
        if (!deviceId.equals(note.getDevice().getId())) throw new ApiException(HttpStatus.NOT_FOUND, "工作记录不存在");
        notes.delete(note);
        audit.record("DEVICE_NOTE_DELETE", "device:" + deviceId, "删除设备工作记录");
    }

    private DeviceNoteDtos.View view(DeviceNote note) {
        return new DeviceNoteDtos.View(note.getId(), note.getDevice().getId(), note.getDevice().getName(), note.getAuthor(), note.getContent(), note.getCreatedAt());
    }

    private int bounded(int limit) { return Math.min(Math.max(limit, 1), 200); }

    private String actor() {
        Authentication authentication = SecurityContextHolder.getContext().getAuthentication();
        return authentication == null || !authentication.isAuthenticated() || authentication.getName() == null
                ? "system" : authentication.getName();
    }
}
