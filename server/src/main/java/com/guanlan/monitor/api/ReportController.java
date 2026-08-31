package com.guanlan.monitor.api;

import com.guanlan.monitor.service.ReportService;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ContentDisposition;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import com.guanlan.monitor.service.DeviceAccessService;

import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Set;

@RestController
@RequestMapping("/api/reports")
@RequiredArgsConstructor
public class ReportController {
    private final ReportService reports;
    private final DeviceAccessService access;

    @GetMapping("/summary")
    ReportService.Summary summary(@RequestParam(required = false) Instant from,
                                  @RequestParam(required = false) Instant to,
                                  Authentication authentication) {
        return reports.summary(from, to, access.visibleDeviceIds(authentication));
    }

    @GetMapping(value = "/summary.csv", produces = "text/csv")
    ResponseEntity<byte[]> csv(@RequestParam(required = false) Instant from,
                               @RequestParam(required = false) Instant to,
                               Authentication authentication) {
        ReportService.Summary summary = reports.summary(from, to, access.visibleDeviceIds(authentication));
        StringBuilder csv = new StringBuilder("# 星辰监控运行报告\n");
        csv.append("时间范围,开始,结束\n");
        csv.append("报告," ).append(summary.from()).append(',').append(summary.to()).append("\n\n");
        csv.append("设备,状态,采集点,平均 CPU %,平均内存 %,平均磁盘 %,峰值压力 %\n");
        for (var device : summary.devices()) {
            csv.append(row(device.name(), device.status(), Integer.toString(device.samples()), Double.toString(device.averageCpu()),
                    Double.toString(device.averageMemory()), Double.toString(device.averageDisk()), Double.toString(device.peakPressure())));
        }
        csv.append("\n服务,类型,探测次数,可用率 %,平均延迟 ms,异常次数\n");
        for (var service : summary.services()) {
            csv.append(row(service.name(), service.type(), Integer.toString(service.samples()), Double.toString(service.availabilityPercent()),
                    Double.toString(service.averageLatencyMs()), Long.toString(service.incidents())));
        }
        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(new MediaType("text", "csv", StandardCharsets.UTF_8));
        headers.setContentDisposition(ContentDisposition.attachment().filename("guanlan-report.csv", StandardCharsets.UTF_8).build());
        return ResponseEntity.ok().headers(headers).body(csv.toString().getBytes(StandardCharsets.UTF_8));
    }

    private String row(String... values) {
        return java.util.Arrays.stream(values).map(this::escape).collect(java.util.stream.Collectors.joining(",")) + "\n";
    }

    private String escape(String value) {
        String safe = value == null ? "" : value.replace("\"", "\"\"");
        return safe.contains(",") || safe.contains("\n") ? "\"" + safe + "\"" : safe;
    }

}
