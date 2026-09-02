package com.guanlan.monitor.repository;

import com.guanlan.monitor.domain.MetricSnapshot;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.time.Instant;
import java.util.List;
import java.util.Optional;

public interface MetricSnapshotRepository extends JpaRepository<MetricSnapshot, Long> {
    Optional<MetricSnapshot> findTopByDeviceIdOrderByCollectedAtDesc(String deviceId);
    Optional<MetricSnapshot> findByDeviceIdAndCollectedAt(String deviceId, Instant collectedAt);
    Optional<MetricSnapshot> findTopByDeviceIdAndCollectedAtLessThanOrderByCollectedAtDesc(String deviceId, Instant collectedAt);
    List<MetricSnapshot> findByDeviceIdAndCollectedAtBetweenOrderByCollectedAtAsc(String deviceId, Instant from, Instant to);
    @Query("""
            select metric.collectedAt as collectedAt,
                   metric.cpuUsage as cpuUsage,
                   metric.memoryUsage as memoryUsage,
                   metric.swapUsage as swapUsage,
                   metric.load1 as load1,
                   metric.load5 as load5,
                   metric.load15 as load15,
                   metric.temperatureMax as temperatureMax,
                   metric.diskUsage as diskUsage,
                   metric.networkSentBps as networkSentBps,
                   metric.networkRecvBps as networkRecvBps
            from MetricSnapshot metric
            where metric.device.id = :deviceId
              and metric.collectedAt between :from and :to
            order by metric.collectedAt asc
            """)
    List<HistorySample> findHistorySamples(@Param("deviceId") String deviceId,
                                           @Param("from") Instant from,
                                           @Param("to") Instant to);
    long countByDeviceId(String deviceId);
    long deleteByCollectedAtBefore(Instant cutoff);

    interface HistorySample {
        Instant getCollectedAt();
        double getCpuUsage();
        double getMemoryUsage();
        double getSwapUsage();
        double getLoad1();
        double getLoad5();
        double getLoad15();
        double getTemperatureMax();
        double getDiskUsage();
        double getNetworkSentBps();
        double getNetworkRecvBps();
    }
}

