package com.guanlan.monitor.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.api.dto.DeviceDtos;
import com.guanlan.monitor.api.dto.MetricView;
import com.guanlan.monitor.api.dto.DeviceHealthDtos;
import com.guanlan.monitor.domain.Device;
import com.guanlan.monitor.repository.DeviceRepository;
import com.guanlan.monitor.repository.MetricSnapshotRepository;
import com.guanlan.monitor.repository.DdnsConfigRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.Authentication;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.security.SecureRandom;
import java.util.Base64;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.time.LocalDate;

@Service
@RequiredArgsConstructor
public class DeviceService {
    private final DeviceRepository devices;
    private final MetricSnapshotRepository metrics;
    private final PasswordEncoder passwordEncoder;
    private final ObjectMapper mapper;
    private final AuditService audit;
    private final DdnsConfigRepository ddnsConfigs;
    private final DeviceHealthService health;
    private final DeviceStatusHistoryService statusHistory;
    private final DeviceAccessService access;
    private final SecureRandom random = new SecureRandom();

    @Transactional(readOnly = true)
    public List<DeviceDtos.View> list() {
        return devices.findAllByOrderByNameAsc().stream().map(this::view).toList();
    }

    @Transactional(readOnly = true)
    public DeviceDtos.View get(String id) { return view(require(id)); }

    @Transactional(readOnly = true)
    public DeviceHealthDtos.View health(String id) {
        Device device = require(id);
        MetricView latest = metrics.findTopByDeviceIdOrderByCollectedAtDesc(id)
                .map(metric -> MetricView.from(metric, mapper)).orElse(null);
        return health.describe(device, latest);
    }

    @Transactional
    public DeviceDtos.Credential create(DeviceDtos.CreateRequest request) {
        return create(request, null);
    }

    @Transactional
    public DeviceDtos.Credential create(DeviceDtos.CreateRequest request, Authentication authentication) {
        String rawKey = newKey();
        Device device = new Device();
        device.setName(request.name());
        device.setLocation(request.location());
        device.setGroupName(request.groupName());
        device.setPrimaryIp(request.primaryIp());
        applyAssetFields(device, request.assetTag(), request.ownerName(), request.vendor(), request.model(), request.serialNumber(), request.environment(), request.purchaseDate(), request.warrantyExpiresAt(), request.description());
        device.setTagsJson(json(normalizeTags(request.tags())));
        device.setDdnsEnabled(request.ddnsEnabled());
        device.setDdnsConfigId(validDdnsConfig(request.ddnsEnabled(), request.ddnsConfigId()));
        device.setPublicVisible(request.publicVisible());
        device.setAgentKeyPrefix(rawKey.substring(0, 8));
        device.setAgentKeyHash(passwordEncoder.encode(rawKey));
        devices.save(device);
        access.grantCreatorAccess(authentication, device);
        statusHistory.record(device, null, Device.Status.PENDING, "设备登记，等待 Agent 首次上报");
        audit.record("DEVICE_CREATE", "device:" + device.getId(), "创建设备 " + device.getName());
        return new DeviceDtos.Credential(view(device), rawKey);
    }

    @Transactional
    public DeviceDtos.View update(String id, DeviceDtos.UpdateRequest request) {
        Device device = require(id);
        device.setName(request.name());
        device.setLocation(request.location());
        device.setGroupName(request.groupName());
        device.setPrimaryIp(request.primaryIp());
        applyAssetFields(device, request.assetTag(), request.ownerName(), request.vendor(), request.model(), request.serialNumber(), request.environment(), request.purchaseDate(), request.warrantyExpiresAt(), request.description());
        device.setTagsJson(json(normalizeTags(request.tags())));
        device.setDdnsEnabled(request.ddnsEnabled());
        device.setDdnsConfigId(validDdnsConfig(request.ddnsEnabled(), request.ddnsConfigId()));
        device.setPublicVisible(request.publicVisible());
        audit.record("DEVICE_UPDATE", "device:" + id, "更新设备 " + device.getName());
        return view(device);
    }

    @Transactional
    public DeviceDtos.Credential regenerateKey(String id) {
        Device device = require(id);
        if (device.isControllerManaged()) {
            throw new ApiException(HttpStatus.CONFLICT, "总控服务器由系统管理，不能轮换 Agent 密钥");
        }
        String rawKey = newKey();
        device.setAgentKeyPrefix(rawKey.substring(0, 8));
        device.setAgentKeyHash(passwordEncoder.encode(rawKey));
        audit.record("DEVICE_KEY_ROTATE", "device:" + id, "轮换 Agent 密钥");
        return new DeviceDtos.Credential(view(device), rawKey);
    }

    @Transactional
    public void delete(String id) {
        Device device = require(id);
        if (device.isControllerManaged()) {
            throw new ApiException(HttpStatus.CONFLICT, "总控服务器由系统管理，不能删除");
        }
        devices.delete(device);
        audit.record("DEVICE_DELETE", "device:" + id, "删除设备 " + device.getName());
    }

    @Transactional(readOnly = true)
    public Device authenticateAgent(String id, String rawKey) {
        Device device = require(id);
        if (rawKey == null || !passwordEncoder.matches(rawKey, device.getAgentKeyHash())) {
            throw new ApiException(HttpStatus.UNAUTHORIZED, "设备凭据无效");
        }
        return device;
    }

    public Device require(String id) {
        return devices.findById(id).orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "设备不存在"));
    }

    public DeviceDtos.View view(Device device) {
        MetricView latest = metrics.findTopByDeviceIdOrderByCollectedAtDesc(device.getId()).map(metric -> MetricView.from(metric, mapper)).orElse(null);
        return new DeviceDtos.View(device.getId(), device.getName(), device.getHostname(), device.getOs(), device.getArchitecture(),
                device.getPrimaryIp(), device.getLocation(), device.getGroupName(), readTags(device.getTagsJson()),
                device.getAssetTag(), device.getOwnerName(), device.getVendor(), device.getModel(), device.getSerialNumber(), device.getEnvironment(),
                device.getPurchaseDate(), device.getWarrantyExpiresAt(), device.getDescription(),
                device.isDdnsEnabled(), device.getDdnsConfigId(), device.isPublicVisible(), device.getStatus(), device.getLastSeenAt(),
                device.getAgentKeyPrefix(), device.isControllerManaged(), device.getCreatedAt(), hardware(device.getHardwareJson()), latest,
                health.describe(device, latest));
    }

    private void applyAssetFields(Device device, String assetTag, String ownerName, String vendor, String model,
                                  String serialNumber, String environment, LocalDate purchaseDate,
                                  LocalDate warrantyExpiresAt, String description) {
        if (purchaseDate != null && warrantyExpiresAt != null && warrantyExpiresAt.isBefore(purchaseDate)) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "保修到期日不能早于采购日期");
        }
        device.setAssetTag(clean(assetTag));
        device.setOwnerName(clean(ownerName));
        device.setVendor(clean(vendor));
        device.setModel(clean(model));
        device.setSerialNumber(clean(serialNumber));
        device.setEnvironment(clean(environment));
        device.setPurchaseDate(purchaseDate);
        device.setWarrantyExpiresAt(warrantyExpiresAt);
        device.setDescription(clean(description));
    }

    private String clean(String value) {
        return value == null || value.isBlank() ? null : value.trim();
    }

    private Long validDdnsConfig(boolean enabled, Long id) {
        if (!enabled) return null;
        if (id == null || !ddnsConfigs.existsById(id)) throw new ApiException(HttpStatus.BAD_REQUEST, "DDNS 配置不存在");
        return id;
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> hardware(String json) {
        if (json == null || json.isBlank()) return Map.of();
        try { return mapper.readValue(json, Map.class); }
        catch (Exception ignored) { return Map.of(); }
    }

    private String newKey() {
        byte[] bytes = new byte[32];
        random.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    private List<String> normalizeTags(List<String> values) {
        if (values == null) return List.of();
        LinkedHashSet<String> unique = new LinkedHashSet<>();
        for (String value : values) {
            if (value == null) continue;
            String tag = value.trim();
            if (tag.isEmpty()) continue;
            if (tag.length() > 40) throw new ApiException(HttpStatus.BAD_REQUEST, "设备标签不能超过 40 个字符");
            unique.add(tag);
            if (unique.size() >= 20) break;
        }
        return List.copyOf(unique);
    }

    private List<String> readTags(String value) {
        if (value == null || value.isBlank()) return List.of();
        try {
            List<String> tags = mapper.readValue(value, mapper.getTypeFactory().constructCollectionType(List.class, String.class));
            return normalizeTags(tags);
        } catch (Exception ignored) {
            return List.of();
        }
    }

    private String json(Object value) {
        try { return mapper.writeValueAsString(value); }
        catch (Exception exception) { throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "设备标签序列化失败"); }
    }
}
