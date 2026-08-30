package com.guanlan.monitor.service;

import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.api.dto.ServiceDtos;
import com.guanlan.monitor.domain.ServiceCheck;
import com.guanlan.monitor.domain.ServiceCheckResult;
import com.guanlan.monitor.repository.ServiceCheckRepository;
import com.guanlan.monitor.repository.ServiceCheckResultRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.Collections;
import java.time.Duration;
import java.time.Instant;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.util.Base64;
import java.util.List;

@Service
@RequiredArgsConstructor
public class ServiceMonitorService {
    private static final Duration AVAILABILITY_WINDOW = Duration.ofDays(7);

    private final ServiceCheckRepository checks;
    private final ServiceCheckResultRepository results;
    private final ServiceProbe probe;
    private final AuditService audit;
    private final NotificationService notifications;
    private final SettingService settings;
    private final SecureRandom random = new SecureRandom();

    @Transactional(readOnly = true)
    public List<ServiceDtos.View> list() {
        return checks.findAllByOrderBySortOrderDescNameAsc().stream().map(this::view).toList();
    }

    @Transactional(readOnly = true)
    public List<ServiceDtos.PublicView> listPublic() {
        return checks.findByEnabledTrueOrderBySortOrderDescNameAsc().stream()
                .filter(ServiceCheck::isPublicVisible)
                .map(this::publicView)
                .toList();
    }

    @Transactional
    public ServiceDtos.View create(ServiceDtos.Request request) {
        validate(request);
        ServiceCheck check = new ServiceCheck();
        String rawToken = apply(check, request);
        checks.save(check);
        audit.record("SERVICE_CREATE", "service:" + check.getId(), "创建服务监控 " + check.getName());
        return view(check, rawToken);
    }

    @Transactional
    public ServiceDtos.View update(Long id, ServiceDtos.Request request) {
        validate(request);
        ServiceCheck check = require(id);
        apply(check, request);
        audit.record("SERVICE_UPDATE", "service:" + id, "更新服务监控 " + check.getName());
        return view(check);
    }

    @Transactional
    public void delete(Long id) {
        ServiceCheck check = require(id);
        results.deleteByServiceCheckId(id);
        checks.delete(check);
        audit.record("SERVICE_DELETE", "service:" + id, "删除服务监控 " + check.getName());
    }

    @Transactional
    public void runEnabledChecks() {
        Instant now = Instant.now();
        for (ServiceCheck check : checks.findByEnabledTrueOrderBySortOrderDescNameAsc()) {
            if (check.getType() == ServiceCheck.Type.HEARTBEAT) {
                evaluateHeartbeatTimeout(check, now);
                continue;
            }
            var latest = results.findTopByServiceCheckIdOrderByCheckedAtDesc(check.getId());
            if (latest.isPresent() && latest.get().getCheckedAt().isAfter(now.minusSeconds(check.getIntervalSeconds()))) continue;
            run(check);
        }
    }

    @Transactional
    public ServiceDtos.View runNow(Long id) {
        ServiceCheck check = require(id);
        if (check.getType() == ServiceCheck.Type.HEARTBEAT) return view(check);
        return view(run(check));
    }

    @Transactional
    public Instant receiveHeartbeat(Long id, String token) {
        ServiceCheck check = require(id);
        if (check.getType() != ServiceCheck.Type.HEARTBEAT || token == null || token.isBlank()
                || check.getHeartbeatTokenHash() == null
                || !MessageDigest.isEqual(hash(token).getBytes(StandardCharsets.UTF_8), check.getHeartbeatTokenHash().getBytes(StandardCharsets.UTF_8))) {
            throw new ApiException(HttpStatus.UNAUTHORIZED, "心跳令牌无效");
        }
        Instant receivedAt = Instant.now();
        ServiceProbe.Result measured = new ServiceProbe.Result(true, 0, null, null, null);
        saveResult(check, receivedAt, measured);
        evaluateAlert(check, measured);
        return receivedAt;
    }

    @Transactional(readOnly = true)
    public List<ServiceDtos.ResultView> history(Long id, Instant from, Instant to) {
        require(id);
        if (from == null || to == null || from.isAfter(to) || Duration.between(from, to).toDays() > 31) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "服务历史时间范围无效或超过 31 天");
        }
        return results.findByServiceCheckIdAndCheckedAtBetweenOrderByCheckedAtAsc(id, from, to).stream().map(result -> new ServiceDtos.ResultView(result.getCheckedAt(), result.isSuccess(), result.getLatencyMs(), result.getStatusCode(), result.getCertificateExpiresAt(), result.getError())).toList();
    }

    private ServiceCheck run(ServiceCheck check) {
        ServiceProbe.Result measured = probe.check(check);
        saveResult(check, Instant.now(), measured);
        evaluateAlert(check, measured);
        return check;
    }

    private void saveResult(ServiceCheck check, Instant checkedAt, ServiceProbe.Result measured) {
        ServiceCheckResult result = new ServiceCheckResult();
        result.setServiceCheck(check);
        result.setCheckedAt(checkedAt);
        result.setSuccess(measured.success());
        result.setLatencyMs(measured.latencyMs());
        result.setStatusCode(measured.statusCode());
        result.setCertificateExpiresAt(measured.certificateExpiresAt());
        result.setError(measured.error());
        results.save(result);
    }

    private void evaluateHeartbeatTimeout(ServiceCheck check, Instant now) {
        var latest = results.findTopByServiceCheckIdOrderByCheckedAtDesc(check.getId());
        if (latest.isEmpty()) {
            if (check.getCreatedAt() == null || now.isBefore(check.getCreatedAt().plusSeconds(staleAfterSeconds(check)))) return;
        } else {
            ServiceCheckResult result = latest.get();
            if (result.isSuccess() && now.isBefore(result.getCheckedAt().plusSeconds(staleAfterSeconds(check)))) return;
            if (!result.isSuccess() && now.isBefore(result.getCheckedAt().plusSeconds(check.getIntervalSeconds()))) return;
        }
        ServiceProbe.Result timeout = new ServiceProbe.Result(false, 0, null, "心跳超时，未在预期时间内收到上报", null);
        saveResult(check, now, timeout);
        evaluateAlert(check, timeout);
    }

    private long staleAfterSeconds(ServiceCheck check) {
        return Math.max(30L, (long) check.getIntervalSeconds() * 2L);
    }

    private ServiceCheck require(Long id) {
        return checks.findById(id).orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "服务监控不存在"));
    }

    private void validate(ServiceDtos.Request request) {
        if (request == null || request.name() == null || request.type() == null) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "服务监控内容无效");
        }
        String target = request.target() == null ? "" : request.target().trim();
        if (request.type() != ServiceCheck.Type.HEARTBEAT && target.isBlank()) throw new ApiException(HttpStatus.BAD_REQUEST, "服务目标不能为空");
        if (request.type() == ServiceCheck.Type.HTTP_GET) {
            try {
                var uri = java.net.URI.create(target);
                if ((!"http".equalsIgnoreCase(uri.getScheme()) && !"https".equalsIgnoreCase(uri.getScheme()))
                        || uri.getHost() == null || uri.getUserInfo() != null || uri.getFragment() != null) {
                    throw new IllegalArgumentException();
                }
            } catch (IllegalArgumentException exception) {
                throw new ApiException(HttpStatus.BAD_REQUEST, "HTTP 目标必须是有效的 http/https 地址");
            }
        }
        if (request.type() == ServiceCheck.Type.TCPING) {
            if (!target.matches("^\\[?[A-Za-z0-9:.%-]+\\]?:[0-9]{1,5}$")) {
                throw new ApiException(HttpStatus.BAD_REQUEST, "TCP 目标必须是 host:port");
            }
            int separator = target.lastIndexOf(':');
            int port;
            try {
                port = Integer.parseInt(target.substring(separator + 1));
            } catch (NumberFormatException exception) {
                throw new ApiException(HttpStatus.BAD_REQUEST, "TCP 端口无效");
            }
            if (port < 1 || port > 65535) throw new ApiException(HttpStatus.BAD_REQUEST, "TCP 端口无效");
        }
    }

    private String apply(ServiceCheck check, ServiceDtos.Request request) {
        check.setName(request.name().trim());
        check.setTarget(request.type() == ServiceCheck.Type.HEARTBEAT ? "external" : request.target().trim());
        check.setType(request.type());
        check.setIntervalSeconds(request.intervalSeconds());
        check.setTimeoutMs(request.timeoutMs());
        check.setPublicVisible(request.publicVisible());
        check.setSortOrder(request.sortOrder());
        check.setEnabled(request.enabled());
        check.setFailureThreshold(request.failureThreshold() == null ? 1 : request.failureThreshold());
        check.setLatencyThresholdMs(request.latencyThresholdMs() == null ? 0 : request.latencyThresholdMs());
        check.setCertificateThresholdDays(request.certificateThresholdDays() == null ? 14 : request.certificateThresholdDays());
        if (request.type() != ServiceCheck.Type.HEARTBEAT) {
            check.setHeartbeatTokenHash(null);
            check.setHeartbeatTokenPrefix(null);
            return null;
        }
        if (check.getHeartbeatTokenHash() != null) return null;
        String rawToken = newToken();
        check.setHeartbeatTokenHash(hash(rawToken));
        check.setHeartbeatTokenPrefix(rawToken.substring(0, 8));
        return rawToken;
    }

    private ServiceDtos.View view(ServiceCheck check) {
        return view(check, null);
    }

    private ServiceDtos.View view(ServiceCheck check, String rawToken) {
        return new ServiceDtos.View(check.getId(), check.getName(), check.getTarget(), check.getType(), check.getIntervalSeconds(), check.getTimeoutMs(), check.isPublicVisible(), check.getSortOrder(), check.isEnabled(), check.getFailureThreshold(), check.getLatencyThresholdMs(), check.getCertificateThresholdDays(), check.isAlertActive(), check.getCreatedAt(), check.getUpdatedAt(), resultView(check), availabilityPercent(check), historyViews(check), check.getHeartbeatTokenPrefix(), rawToken, check.getType() == ServiceCheck.Type.HEARTBEAT ? "/api/heartbeat/" + check.getId() : null);
    }

    private ServiceDtos.PublicView publicView(ServiceCheck check) {
        return new ServiceDtos.PublicView(check.getId(), check.getName(), check.getType(), check.getSortOrder(), publicResultView(check), availabilityPercent(check), publicHistoryViews(check));
    }

    private ServiceDtos.ResultView resultView(ServiceCheck check) {
        return results.findTopByServiceCheckIdOrderByCheckedAtDesc(check.getId()).map(result -> new ServiceDtos.ResultView(result.getCheckedAt(), result.isSuccess(), result.getLatencyMs(), result.getStatusCode(), result.getCertificateExpiresAt(), result.getError())).orElse(null);
    }

    private ServiceDtos.PublicResultView publicResultView(ServiceCheck check) {
        return results.findTopByServiceCheckIdOrderByCheckedAtDesc(check.getId()).map(result -> new ServiceDtos.PublicResultView(result.getCheckedAt(), result.isSuccess(), result.getLatencyMs(), result.getStatusCode(), result.getCertificateExpiresAt())).orElse(null);
    }

    private List<ServiceDtos.ResultView> historyViews(ServiceCheck check) {
        var recent = new ArrayList<>(results.findTop60ByServiceCheckIdOrderByCheckedAtDesc(check.getId()));
        Collections.reverse(recent);
        return recent.stream().map(result -> new ServiceDtos.ResultView(result.getCheckedAt(), result.isSuccess(), result.getLatencyMs(), result.getStatusCode(), result.getCertificateExpiresAt(), result.getError())).toList();
    }

    private List<ServiceDtos.PublicResultView> publicHistoryViews(ServiceCheck check) {
        var recent = new ArrayList<>(results.findTop60ByServiceCheckIdOrderByCheckedAtDesc(check.getId()));
        Collections.reverse(recent);
        return recent.stream().map(result -> new ServiceDtos.PublicResultView(result.getCheckedAt(), result.isSuccess(), result.getLatencyMs(), result.getStatusCode(), result.getCertificateExpiresAt())).toList();
    }

    private Double availabilityPercent(ServiceCheck check) {
        Instant from = Instant.now().minus(AVAILABILITY_WINDOW);
        long total = results.countByServiceCheckIdAndCheckedAtBetween(check.getId(), from, Instant.now());
        if (total == 0) return null;
        long successful = results.countByServiceCheckIdAndSuccessTrueAndCheckedAtBetween(check.getId(), from, Instant.now());
        return Math.round(successful * 10000d / total) / 100d;
    }

    private void evaluateAlert(ServiceCheck check, ServiceProbe.Result measured) {
        boolean failure = !measured.success();
        if (failure) check.setConsecutiveFailures(check.getConsecutiveFailures() + 1);
        else check.setConsecutiveFailures(0);
        boolean latencyBreach = check.getLatencyThresholdMs() > 0 && measured.latencyMs() >= check.getLatencyThresholdMs();
        Instant now = Instant.now();
        boolean certificateBreach = check.getCertificateThresholdDays() > 0
                && measured.certificateExpiresAt() != null
                && !measured.certificateExpiresAt().isAfter(now.plus(Duration.ofDays(check.getCertificateThresholdDays())));
        boolean breached = (failure && check.getConsecutiveFailures() >= check.getFailureThreshold()) || latencyBreach || certificateBreach;
        if (breached && !check.isAlertActive()) {
            check.setAlertActive(true);
            String reason = failure ? "连续失败 " + check.getConsecutiveFailures() + " 次"
                    : certificateBreach ? "证书将在 " + Math.max(0, Duration.between(now, measured.certificateExpiresAt()).toDays()) + " 天内到期"
                    : "延迟 " + measured.latencyMs() + " ms";
            notifications.sendMessage("[" + settings.publicBrand().siteName() + "] 服务“" + check.getName() + "”异常：" + reason + "，目标 " + check.getTarget());
        } else if (!breached && check.isAlertActive()) {
            check.setAlertActive(false);
            notifications.sendMessage("[" + settings.publicBrand().siteName() + "] 服务“" + check.getName() + "”已恢复，当前延迟 " + measured.latencyMs() + " ms");
        }
    }

    private String newToken() {
        byte[] bytes = new byte[32];
        random.nextBytes(bytes);
        return "hb_" + Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    private String hash(String value) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));
            StringBuilder result = new StringBuilder(digest.length * 2);
            for (byte item : digest) result.append(String.format("%02x", item));
            return result.toString();
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 不可用", exception);
        }
    }
}
