package com.guanlan.monitor.domain;

import jakarta.persistence.*;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.Instant;

@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "metric_snapshots", indexes = {
        @Index(name = "idx_metrics_device_collected", columnList = "device_id,collected_at"),
        @Index(name = "idx_metrics_collected", columnList = "collected_at")
})
public class MetricSnapshot {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "device_id", nullable = false)
    private Device device;

    @Column(name = "collected_at", nullable = false)
    private Instant collectedAt;

    @Column(name = "cpu_usage", nullable = false)
    private double cpuUsage;

    @Column(name = "memory_usage", nullable = false)
    private double memoryUsage;

    @Column(name = "swap_usage", nullable = false)
    private double swapUsage;

    @Column(name = "load_1", nullable = false)
    private double load1;

    @Column(name = "load_5", nullable = false)
    private double load5;

    @Column(name = "load_15", nullable = false)
    private double load15;

    @Column(name = "disk_usage", nullable = false)
    private double diskUsage;

    @Column(name = "disk_read_bps", nullable = false)
    private double diskReadBps;

    @Column(name = "disk_write_bps", nullable = false)
    private double diskWriteBps;

    @Column(name = "network_sent_bps", nullable = false)
    private double networkSentBps;

    @Column(name = "network_recv_bps", nullable = false)
    private double networkRecvBps;

    @Column(name = "network_sent_bytes", nullable = false)
    private long networkSentBytes;

    @Column(name = "network_recv_bytes", nullable = false)
    private long networkRecvBytes;

    @Column(name = "tcp_connections", nullable = false)
    private int tcpConnections;

    @Column(name = "temperature_max", nullable = false)
    private double temperatureMax;

    @Column(name = "gpu_usage")
    private Double gpuUsage;

    @Column(name = "battery_percent")
    private Double batteryPercent;

    @Column(name = "container_cpu_usage")
    private Double containerCpuUsage;

    @Column(name = "container_memory_usage")
    private Double containerMemoryUsage;

    @Column(name = "smart_passed", nullable = false)
    private int smartPassed;

    @Column(name = "smart_failed", nullable = false)
    private int smartFailed;

    @Column(name = "smart_unknown", nullable = false)
    private int smartUnknown;

    @Column(name = "integrity_changes", nullable = false)
    private int integrityChanges;

    @Column(name = "firewall_inactive")
    private Integer firewallInactive;

    @Column(name = "disks_json", columnDefinition = "TEXT")
    private String disksJson;

    @Column(name = "processes_json", columnDefinition = "TEXT")
    private String processesJson;

    @Column(name = "services_json", columnDefinition = "TEXT")
    private String servicesJson;

    @Column(name = "network_interfaces_json", columnDefinition = "TEXT")
    private String networkInterfacesJson;

    @Column(name = "ports_json", columnDefinition = "TEXT")
    private String portsJson;

    @Column(name = "containers_json", columnDefinition = "TEXT")
    private String containersJson;

    @Column(name = "fans_json", columnDefinition = "TEXT")
    private String fansJson;

    @Column(name = "batteries_json", columnDefinition = "TEXT")
    private String batteriesJson;

    @Column(name = "gpus_json", columnDefinition = "TEXT")
    private String gpusJson;

    @Column(name = "firewall_json", columnDefinition = "TEXT")
    private String firewallJson;

    @Column(name = "cron_jobs_json", columnDefinition = "TEXT")
    private String cronJobsJson;

    @Column(name = "logs_json", columnDefinition = "TEXT")
    private String logsJson;

    @Column(name = "system_logs_json", columnDefinition = "TEXT")
    private String systemLogsJson;

    @Column(name = "integrity_json", columnDefinition = "TEXT")
    private String integrityJson;

    @Column(name = "custom_metrics_json", columnDefinition = "TEXT")
    private String customMetricsJson;
}
