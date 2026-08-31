package com.guanlan.monitor.service;

import com.guanlan.monitor.api.dto.DeviceDtos;
import com.guanlan.monitor.api.dto.TopologyDtos;
import com.guanlan.monitor.domain.ServiceCheck;
import com.guanlan.monitor.repository.ServiceCheckRepository;
import com.guanlan.monitor.repository.ServiceCheckResultRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.net.URI;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

@Service
@RequiredArgsConstructor
public class TopologyService {
    private static final String CONTROLLER_ID = "controller";

    private final DeviceService devices;
    private final ServiceCheckRepository checks;
    private final ServiceCheckResultRepository results;

    @Transactional(readOnly = true)
    public TopologyDtos.View build(Set<String> visibleDeviceIds) {
        List<DeviceDtos.View> allDevices = devices.list().stream()
                .filter(device -> visibleDeviceIds == null || visibleDeviceIds.contains(device.id()))
                .toList();
        Map<String, DeviceDtos.View> byIdentifier = new HashMap<>();
        List<TopologyDtos.Node> nodes = new ArrayList<>();
        nodes.add(new TopologyDtos.Node(CONTROLLER_ID, "总控", "CONTROLLER", "ONLINE", null, null, null, null, null, 0));
        for (DeviceDtos.View device : allDevices) {
            String address = firstNonBlank(device.primaryIp(), device.hostname());
            var latest = device.latest();
            nodes.add(new TopologyDtos.Node(
                    device.id(), device.name(), "DEVICE", device.status().name(), device.hostname(), address,
                    latest == null ? null : latest.cpuUsage(), latest == null ? null : latest.memoryUsage(), latest == null ? null : latest.diskUsage(), 0));
            identifiers(device).forEach(identifier -> byIdentifier.putIfAbsent(identifier, device));
        }

        List<TopologyDtos.Edge> edges = new ArrayList<>();
        Map<String, Integer> serviceCounts = new HashMap<>();
        int unresolved = 0;
        for (ServiceCheck check : checks.findAllByOrderBySortOrderDescNameAsc()) {
            String host = targetHost(check.getTarget(), check.getType());
            DeviceDtos.View targetDevice = byIdentifier.get(normalize(host));
            String targetId;
            if (targetDevice != null) {
                targetId = targetDevice.id();
                serviceCounts.merge(targetId, 1, Integer::sum);
            } else {
                unresolved++;
                targetId = "external:" + check.getId();
                nodes.add(new TopologyDtos.Node(targetId, host.isBlank() ? "外部服务" : host, "EXTERNAL", "UNKNOWN", null, host.isBlank() ? null : host, null, null, null, 1));
            }
            var latest = results.findTopByServiceCheckIdOrderByCheckedAtDesc(check.getId()).orElse(null);
            edges.add(new TopologyDtos.Edge(
                    "service:" + check.getId(), CONTROLLER_ID, targetId, check.getName(), check.getType(),
                    !check.isEnabled() ? "DISABLED" : latest == null ? "UNKNOWN" : latest.isSuccess() ? "UP" : "DOWN",
                    latest == null ? null : latest.getLatencyMs(), host));
        }

        List<TopologyDtos.Node> updatedNodes = new ArrayList<>(nodes.size());
        for (TopologyDtos.Node node : nodes) {
            updatedNodes.add(node.kind().equals("DEVICE")
                    ? new TopologyDtos.Node(node.id(), node.label(), node.kind(), node.status(), node.hostname(), node.address(), node.cpuUsage(), node.memoryUsage(), node.diskUsage(), serviceCounts.getOrDefault(node.id(), 0))
                    : node);
        }
        return new TopologyDtos.View(List.copyOf(updatedNodes), List.copyOf(edges), edges.size(), unresolved);
    }

    static String targetHost(String target, ServiceCheck.Type type) {
        if (target == null || target.isBlank() || type == ServiceCheck.Type.HEARTBEAT) return "";
        String value = target.trim();
        try {
            if (value.contains("://")) {
                URI uri = URI.create(value);
                return normalize(uri.getHost());
            }
            if (value.startsWith("[")) {
                int close = value.indexOf(']');
                if (close > 0) return normalize(value.substring(1, close));
            }
            if (value.matches("^.+:[0-9]{1,5}$")) return normalize(value.substring(0, value.lastIndexOf(':')));
        } catch (IllegalArgumentException ignored) {
            return normalize(value);
        }
        return normalize(value);
    }

    private Set<String> identifiers(DeviceDtos.View device) {
        Set<String> values = new HashSet<>();
        values.add(normalize(device.name()));
        values.add(normalize(device.hostname()));
        values.add(normalize(device.primaryIp()));
        values.remove("");
        return values;
    }

    private static String normalize(String value) {
        if (value == null) return "";
        String result = value.trim().toLowerCase(Locale.ROOT);
        while (result.endsWith(".")) result = result.substring(0, result.length() - 1);
        return result;
    }

    private static String firstNonBlank(String first, String second) {
        return first != null && !first.isBlank() ? first : second;
    }
}
