package com.guanlan.monitor.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.api.dto.AgentReportRequest;
import org.junit.jupiter.api.Test;
import java.util.List;
import static org.assertj.core.api.Assertions.assertThat;

class MetricDiskThroughputTest {
    @Test
    void sumsIndependentCountersOnceAndIgnoresUnsupportedMounts() {
        var disks = List.of(disk("/", "block:253:0", true, 100, 10),
                disk("/bind", "block:253:0", true, 100, 10),
                disk("/data", "block:253:1", true, 200, 20),
                disk("/nfs", "", false, 900, 900));
        assertThat(MetricService.diskThroughput(disks, true)).isEqualTo(300);
        assertThat(MetricService.diskThroughput(disks, false)).isEqualTo(30);
    }

    @Test
    void preservesLegacyHostTotalRepeatedOnEveryMount() throws Exception {
        var old = new ObjectMapper().readValue("""
                {"device":"/dev/vda1","mountpoint":"/","readBytesPerSec":300,"writeBytesPerSec":30}
                """, AgentReportRequest.DiskStats.class);
        assertThat(old.ioAvailable()).isNull();
        assertThat(old.ioDevice()).isNull();
        assertThat(MetricService.diskThroughput(List.of(old, old), true)).isEqualTo(300);
        assertThat(MetricService.diskThroughput(List.of(old, old), false)).isEqualTo(30);
    }

    @Test
    void doesNotPromoteUnknownCountersInAnExplicitNewReport() {
        assertThat(MetricService.diskThroughput(List.of(disk("/", "block:253:0", false, 10, 10)), true)).isZero();
        assertThat(MetricService.diskThroughput(List.of(), true)).isZero();
    }

    private AgentReportRequest.DiskStats disk(String mount, String counter, Boolean available, double read, double write) {
        return new AgentReportRequest.DiskStats("/dev/disk", mount, "ext4", 1000, 100, 900, 10, read, write, null, counter, available);
    }
}
