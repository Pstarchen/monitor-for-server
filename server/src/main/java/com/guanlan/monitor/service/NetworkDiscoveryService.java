package com.guanlan.monitor.service;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.api.dto.DiscoveryDtos;
import com.guanlan.monitor.domain.DiscoveryResult;
import com.guanlan.monitor.domain.DiscoveryScan;
import com.guanlan.monitor.repository.DiscoveryResultRepository;
import com.guanlan.monitor.repository.DiscoveryScanRepository;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.userdetails.UserDetails;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.scheduling.concurrent.ThreadPoolTaskExecutor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.context.event.EventListener;
import org.springframework.boot.context.event.ApplicationReadyEvent;

import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

@Service
public class NetworkDiscoveryService {
    private static final List<Integer> DEFAULT_PORTS = List.of(22, 80, 443, 3000, 5432, 6379, 8080, 9090);
    private static final int DEFAULT_TIMEOUT_MS = 500;
    private static final int DEFAULT_CONCURRENCY = 16;
    private static final int MAX_HOSTS = 256;
    private final DiscoveryScanRepository scans;
    private final DiscoveryResultRepository results;
    private final ObjectMapper mapper;
    private final AuditService audit;
    private final ThreadPoolTaskExecutor executor;
    private final Map<Long, AtomicBoolean> cancellations = new ConcurrentHashMap<>();

    public NetworkDiscoveryService(DiscoveryScanRepository scans, DiscoveryResultRepository results, ObjectMapper mapper,
                                   AuditService audit, @Qualifier("discoveryExecutor") ThreadPoolTaskExecutor executor) {
        this.scans = scans;
        this.results = results;
        this.mapper = mapper;
        this.audit = audit;
        this.executor = executor;
    }

    @Transactional
    public DiscoveryDtos.View start(DiscoveryDtos.StartRequest request, String actor, Authentication authentication) {
        requireSession(authentication);
        Normalized normalized = normalize(request);
        DiscoveryScan scan = new DiscoveryScan();
        scan.setCidr(normalized.cidr());
        scan.setPortsJson(json(normalized.ports()));
        scan.setTimeoutMs(normalized.timeoutMs());
        scan.setConcurrency(normalized.concurrency());
        scan.setTotalHosts(normalized.addresses().size());
        scan.setCreatedBy(actor == null || actor.isBlank() ? "system" : actor);
        scans.save(scan);
        cancellations.put(scan.getId(), new AtomicBoolean(false));
        audit.record("DISCOVERY_START", "discovery:" + scan.getId(), "扫描网段 " + scan.getCidr());
        scheduleAfterCommit(scan.getId(), normalized);
        return view(scan);
    }

    @Transactional(readOnly = true)
    public List<DiscoveryDtos.View> list(int limit, Authentication authentication) {
        requireSession(authentication);
        return scans.findAllByOrderByCreatedAtDesc(org.springframework.data.domain.PageRequest.of(0, Math.min(Math.max(limit, 1), 100)))
                .stream().map(this::view).toList();
    }

    @Transactional(readOnly = true)
    public DiscoveryDtos.Detail get(Long id, Authentication authentication) {
        requireSession(authentication);
        DiscoveryScan scan = require(id);
        List<DiscoveryDtos.ResultView> found = results.findAllByScanIdOrderByDiscoveredAtDesc(id).stream().map(this::resultView).toList();
        return new DiscoveryDtos.Detail(view(scan), found);
    }

    @Transactional
    public DiscoveryDtos.View cancel(Long id, Authentication authentication) {
        requireSession(authentication);
        DiscoveryScan scan = require(id);
        if (scan.getStatus() == DiscoveryScan.Status.QUEUED || scan.getStatus() == DiscoveryScan.Status.RUNNING) {
            cancellations.computeIfAbsent(id, ignored -> new AtomicBoolean()).set(true);
            scan.setStatus(DiscoveryScan.Status.CANCELED);
            scan.setFinishedAt(Instant.now());
            scan.setError("扫描已取消");
            audit.record("DISCOVERY_CANCEL", "discovery:" + id, "取消网段扫描");
        }
        return view(scan);
    }

    @EventListener(ApplicationReadyEvent.class)
    @Transactional
    public void recoverInterruptedScans() {
        scans.findByStatusIn(List.of(DiscoveryScan.Status.QUEUED, DiscoveryScan.Status.RUNNING)).forEach(scan -> {
            scan.setStatus(DiscoveryScan.Status.FAILED);
            scan.setFinishedAt(Instant.now());
            scan.setError("总控服务重启导致扫描中断，请重新发起");
            scans.save(scan);
        });
    }

    private void scheduleAfterCommit(Long id, Normalized normalized) {
        Runnable task = () -> executor.execute(() -> runScan(id, normalized));
        if (TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
                @Override public void afterCommit() { task.run(); }
            });
        } else {
            task.run();
        }
    }

    private void runScan(Long id, Normalized normalized) {
        DiscoveryScan scan = scans.findById(id).orElse(null);
        if (scan == null || scan.getStatus() == DiscoveryScan.Status.CANCELED) return;
        scan.setStatus(DiscoveryScan.Status.RUNNING);
        scan.setStartedAt(Instant.now());
        scans.save(scan);
        AtomicBoolean canceled = cancellations.computeIfAbsent(id, ignored -> new AtomicBoolean(false));
        AtomicInteger scanned = new AtomicInteger(0);
        AtomicInteger discovered = new AtomicInteger(0);
        try (ExecutorService pool = Executors.newFixedThreadPool(normalized.concurrency())) {
            List<Future<ProbeResult>> futures = new ArrayList<>();
            for (String address : normalized.addresses()) {
                futures.add(pool.submit(() -> probe(address, normalized.ports(), normalized.timeoutMs())));
            }
            for (Future<ProbeResult> future : futures) {
                if (canceled.get()) break;
                try {
                    ProbeResult result = future.get();
                    if (result.reachable() || !result.openPorts().isEmpty()) {
                        results.save(new DiscoveryResult(scan, result.address(), null, result.reachable(), json(result.openPorts()), result.latencyMs()));
                        discovered.incrementAndGet();
                    }
                } catch (Exception ignored) {
                    // A single unreachable host must not fail the entire scan.
                } finally {
                    scanned.incrementAndGet();
                    updateProgress(id, scanned.get(), discovered.get());
                }
            }
            futures.forEach(future -> { if (!future.isDone()) future.cancel(true); });
        } catch (Exception exception) {
            finish(id, DiscoveryScan.Status.FAILED, "扫描执行失败，请稍后重试");
            return;
        }
        if (canceled.get()) finish(id, DiscoveryScan.Status.CANCELED, "扫描已取消");
        else finish(id, DiscoveryScan.Status.SUCCEEDED, null);
        cancellations.remove(id);
    }

    private ProbeResult probe(String address, List<Integer> ports, int timeoutMs) {
        long started = System.nanoTime();
        boolean reachable = false;
        try {
            byte[] bytes = new byte[4];
            String[] parts = address.split("\\.");
            for (int index = 0; index < 4; index++) bytes[index] = (byte) Integer.parseInt(parts[index]);
            reachable = InetAddress.getByAddress(bytes).isReachable(timeoutMs);
        } catch (Exception ignored) { }
        List<Integer> openPorts = new ArrayList<>();
        for (Integer port : ports) {
            if (Thread.currentThread().isInterrupted()) break;
            try (Socket socket = new Socket()) {
                socket.connect(new InetSocketAddress(address, port), timeoutMs);
                openPorts.add(port);
                reachable = true;
            } catch (Exception ignored) { }
        }
        Integer latency = reachable ? Math.max(1, (int) ((System.nanoTime() - started) / 1_000_000)) : null;
        return new ProbeResult(address, reachable, List.copyOf(openPorts), latency);
    }

    private void updateProgress(Long id, int scanned, int discovered) {
        scans.findById(id).ifPresent(scan -> {
            if (scan.getStatus() == DiscoveryScan.Status.CANCELED) return;
            scan.setScannedHosts(Math.min(scanned, scan.getTotalHosts()));
            scan.setDiscoveredHosts(Math.min(discovered, scan.getTotalHosts()));
            scans.save(scan);
        });
    }

    private void finish(Long id, DiscoveryScan.Status status, String error) {
        scans.findById(id).ifPresent(scan -> {
            if (scan.getStatus() == DiscoveryScan.Status.CANCELED && status != DiscoveryScan.Status.CANCELED) return;
            scan.setStatus(status);
            scan.setFinishedAt(Instant.now());
            scan.setError(error);
            if (status == DiscoveryScan.Status.SUCCEEDED) scan.setScannedHosts(scan.getTotalHosts());
            scans.save(scan);
            audit.record("DISCOVERY_FINISH", "discovery:" + id, "网段扫描完成，状态 " + status.name());
        });
    }

    private Normalized normalize(DiscoveryDtos.StartRequest request) {
        if (request == null || request.cidr() == null) throw new ApiException(HttpStatus.BAD_REQUEST, "请输入 IPv4 CIDR 网段");
        Cidr parsed = parseCidr(request.cidr());
        List<Integer> ports = normalizePorts(request.ports());
        int timeout = request.timeoutMs() == null ? DEFAULT_TIMEOUT_MS : request.timeoutMs();
        int concurrency = request.concurrency() == null ? DEFAULT_CONCURRENCY : request.concurrency();
        if (timeout < 50 || timeout > 3000) throw new ApiException(HttpStatus.BAD_REQUEST, "探测超时必须在 50 到 3000 毫秒之间");
        if (concurrency < 1 || concurrency > 32) throw new ApiException(HttpStatus.BAD_REQUEST, "并发数必须在 1 到 32 之间");
        List<String> addresses = new ArrayList<>(parsed.count());
        for (long value = parsed.network(); value <= parsed.last(); value++) addresses.add(longToIp(value));
        return new Normalized(parsed.normalized(), ports, timeout, concurrency, List.copyOf(addresses));
    }

    private Cidr parseCidr(String raw) {
        String value = raw.trim();
        String[] parts = value.split("/", -1);
        if (parts.length != 2 || parts[0].isBlank()) throw new ApiException(HttpStatus.BAD_REQUEST, "CIDR 格式无效，例如 192.168.1.0/24");
        int prefix;
        try { prefix = Integer.parseInt(parts[1]); } catch (NumberFormatException exception) { throw new ApiException(HttpStatus.BAD_REQUEST, "CIDR 前缀无效"); }
        if (prefix < 24 || prefix > 32) throw new ApiException(HttpStatus.BAD_REQUEST, "扫描范围必须是 /24 到 /32，最多 256 个地址");
        long ip = parseIp(parts[0]);
        long mask = prefix == 0 ? 0 : (0xffffffffL << (32 - prefix)) & 0xffffffffL;
        long network = ip & mask;
        long count = 1L << (32 - prefix);
        long last = network + count - 1;
        if (count > MAX_HOSTS) throw new ApiException(HttpStatus.BAD_REQUEST, "扫描地址数量不能超过 " + MAX_HOSTS);
        if (!isPrivate(network) || !isPrivate(last)) throw new ApiException(HttpStatus.BAD_REQUEST, "为避免误探测，仅允许扫描 RFC1918 私网地址");
        return new Cidr(longToIp(network) + "/" + prefix, network, last, (int) count);
    }

    private long parseIp(String value) {
        String[] parts = value.split("\\.", -1);
        if (parts.length != 4) throw new ApiException(HttpStatus.BAD_REQUEST, "仅支持 IPv4 地址");
        long result = 0;
        for (String part : parts) {
            if (!part.matches("(?:0|[1-9]\\d{0,2})")) throw new ApiException(HttpStatus.BAD_REQUEST, "IPv4 地址格式无效");
            int octet;
            try { octet = Integer.parseInt(part); } catch (NumberFormatException exception) { throw new ApiException(HttpStatus.BAD_REQUEST, "IPv4 地址格式无效"); }
            if (octet > 255) throw new ApiException(HttpStatus.BAD_REQUEST, "IPv4 地址范围无效");
            result = (result << 8) | octet;
        }
        return result;
    }

    private boolean isPrivate(long value) {
        int first = (int) ((value >>> 24) & 255);
        int second = (int) ((value >>> 16) & 255);
        return first == 10 || (first == 172 && second >= 16 && second <= 31) || (first == 192 && second == 168);
    }

    private String longToIp(long value) {
        return ((value >>> 24) & 255) + "." + ((value >>> 16) & 255) + "." + ((value >>> 8) & 255) + "." + (value & 255);
    }

    private List<Integer> normalizePorts(List<Integer> input) {
        List<Integer> source = input == null || input.isEmpty() ? DEFAULT_PORTS : input;
        LinkedHashSet<Integer> unique = new LinkedHashSet<>();
        for (Integer port : source) {
            if (port == null || port < 1 || port > 65535) throw new ApiException(HttpStatus.BAD_REQUEST, "端口必须在 1 到 65535 之间");
            unique.add(port);
            if (unique.size() > 32) throw new ApiException(HttpStatus.BAD_REQUEST, "最多同时探测 32 个端口");
        }
        return List.copyOf(unique);
    }

    private void requireSession(Authentication authentication) {
        if (authentication == null || !(authentication.getPrincipal() instanceof UserDetails)) {
            throw new ApiException(HttpStatus.FORBIDDEN, "网络发现仅支持登录会话");
        }
        if (authentication.getPrincipal() instanceof com.guanlan.monitor.security.ApiTokenPrincipal) {
            throw new ApiException(HttpStatus.FORBIDDEN, "API Token 不能发起网络发现");
        }
    }

    private DiscoveryScan require(Long id) { return scans.findById(id).orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "扫描任务不存在")); }

    private DiscoveryDtos.View view(DiscoveryScan scan) {
        return new DiscoveryDtos.View(scan.getId(), scan.getCidr(), parsePorts(scan.getPortsJson()), scan.getTimeoutMs(), scan.getConcurrency(), scan.getStatus(), scan.getTotalHosts(), scan.getScannedHosts(), scan.getDiscoveredHosts(), scan.getCreatedBy(), scan.getCreatedAt(), scan.getStartedAt(), scan.getFinishedAt(), scan.getError());
    }

    private DiscoveryDtos.ResultView resultView(DiscoveryResult result) { return new DiscoveryDtos.ResultView(result.getId(), result.getAddress(), result.getHostname(), result.isReachable(), parsePorts(result.getOpenPortsJson()), result.getLatencyMs(), result.getDiscoveredAt()); }

    private List<Integer> parsePorts(String value) {
        try { return mapper.readValue(value, mapper.getTypeFactory().constructCollectionType(List.class, Integer.class)); }
        catch (Exception ignored) { return List.of(); }
    }

    private String json(Object value) {
        try { return mapper.writeValueAsString(value); }
        catch (JsonProcessingException exception) { throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "扫描参数保存失败"); }
    }

    private record Normalized(String cidr, List<Integer> ports, int timeoutMs, int concurrency, List<String> addresses) {}
    private record Cidr(String normalized, long network, long last, int count) {}
    private record ProbeResult(String address, boolean reachable, List<Integer> openPorts, Integer latencyMs) {}
}
