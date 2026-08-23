package com.guanlan.monitor.service;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.api.dto.DdnsDtos;
import com.guanlan.monitor.domain.DdnsConfig;
import com.guanlan.monitor.domain.Device;
import com.guanlan.monitor.repository.DdnsConfigRepository;
import com.guanlan.monitor.repository.DeviceRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.client.RestClient;
import org.springframework.http.client.SimpleClientHttpRequestFactory;

import java.net.InetAddress;
import java.net.URI;
import java.time.Instant;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

@Service
@RequiredArgsConstructor
public class DdnsService {
    private static final TypeReference<Map<String, String>> HEADERS = new TypeReference<>() {};
    private final DdnsConfigRepository configs;
    private final ObjectMapper mapper;
    private final SecretValueCodec secrets;
    private final AuditService audit;
    private final DeviceRepository devices;
    private final RestClient client = RestClient.builder().requestFactory(requestFactory()).build();

    @Transactional(readOnly = true)
    public List<DdnsDtos.View> list() { return list(true); }

    @Transactional(readOnly = true)
    public List<DdnsDtos.View> list(boolean includeErrorDetails) {
        return configs.findAll().stream().map(config -> view(config, includeErrorDetails)).toList();
    }

    @Transactional
    public DdnsDtos.View create(DdnsDtos.Request request, String actor) {
        validate(request);
        DdnsConfig config = new DdnsConfig();
        apply(config, request, false);
        configs.save(config);
        audit.record("DDNS_CREATE", "ddns:" + config.getId(), "创建 DDNS 配置 " + config.getName());
        return view(config);
    }

    @Transactional
    public DdnsDtos.View update(Long id, DdnsDtos.Request request, String actor) {
        validate(request);
        DdnsConfig config = require(id);
        apply(config, request, true);
        audit.record("DDNS_UPDATE", "ddns:" + id, "更新 DDNS 配置 " + config.getName());
        return view(config);
    }

    @Transactional
    public void delete(Long id, String actor) {
        DdnsConfig config = require(id);
        configs.delete(config);
        audit.record("DDNS_DELETE", "ddns:" + id, "删除 DDNS 配置 " + config.getName());
    }

    @Transactional
    public DdnsDtos.View test(Long id, String ip, String actor) {
        DdnsConfig config = require(id);
        String normalizedIp = normalizeIp(ip);
        updateConfig(config, normalizedIp, isIpv6(normalizedIp) ? "ipv6" : "ipv4");
        audit.record("DDNS_TEST", "ddns:" + id, "测试 DDNS 配置");
        return view(config);
    }

    @Async
    @Transactional
    public void updateForDevice(Device device, String ip) {
        if (!device.isDdnsEnabled() || device.getDdnsConfigId() == null || ip == null || ip.isBlank()) return;
        final String normalizedIp;
        try {
            normalizedIp = normalizeIp(ip);
        } catch (ApiException ignored) {
            return;
        }
        Device current = devices.findById(device.getId()).orElse(null);
        if (current == null) return;
        DdnsConfig config = configs.findById(device.getDdnsConfigId()).orElse(null);
        if (config == null || !config.isEnabled()) return;
        String type = isIpv6(normalizedIp) ? "ipv6" : "ipv4";
        if ((type.equals("ipv4") && !config.isIpv4Enabled()) || (type.equals("ipv6") && !config.isIpv6Enabled())) return;
        String previous = type.equals("ipv6") ? current.getLastDdnsIpv6() : current.getLastDdnsIpv4();
        if (normalizedIp.equals(previous)) return;
        if (updateConfig(config, normalizedIp, type)) {
            if (type.equals("ipv6")) current.setLastDdnsIpv6(normalizedIp); else current.setLastDdnsIpv4(normalizedIp);
            audit.record("DDNS_AUTO_UPDATE", "device:" + current.getId(), "更新设备 " + current.getName() + " 的 " + type.toUpperCase(Locale.ROOT) + " 记录");
        }
    }

    private boolean updateConfig(DdnsConfig config, String ip, String type) {
        String record = type.equals("ipv6") ? "AAAA" : "A";
        List<String> domains = domains(config.getDomains());
        String lastError = "";
        for (String domain : domains) {
            boolean success = false;
            for (int attempt = 1; attempt <= config.getMaxRetries() && !success; attempt++) {
                try { send(config, domain, ip, type, record); success = true; }
                catch (Exception exception) { lastError = truncate(exception.getMessage()); }
            }
            if (!success) {
                config.setLastStatus("FAILED"); config.setLastError(lastError); config.setLastUpdatedAt(Instant.now());
                return false;
            }
        }
        config.setLastStatus("SUCCEEDED"); config.setLastError(""); config.setLastUpdatedAt(Instant.now());
        return true;
    }

    private void send(DdnsConfig config, String domain, String ip, String type, String record) throws Exception {
        if (config.getProvider() == DdnsConfig.Provider.DUMMY) return;
        if (config.getWebhookUrl() == null || config.getWebhookUrl().isBlank()) throw new IllegalArgumentException("Webhook URL 未配置");
        String url = expand(config.getWebhookUrl(), domain, ip, type, record, config);
        URI uri = URI.create(url);
        HttpMethod method = HttpMethod.valueOf(config.getHttpMethod().name());
        var request = client.method(method).uri(uri);
        Map<String, String> headers = parseHeaders(config.getHeadersJson());
        headers.forEach((key, value) -> request.header(key, expand(value, domain, ip, type, record, config)));
        String body = expand(config.getBodyTemplate(), domain, ip, type, record, config);
        if (method == HttpMethod.GET || method == HttpMethod.DELETE) request.retrieve().toBodilessEntity();
        else request.body(body == null ? "" : body).retrieve().toBodilessEntity();
    }

    private void apply(DdnsConfig config, DdnsDtos.Request request, boolean preserveSecrets) {
        config.setName(request.name().trim()); config.setProvider(request.provider()); config.setDomains(String.join(",", normalizeDomains(request.domains())));
        if (!blank(request.webhookUrl()) || !preserveSecrets) config.setWebhookUrl(blank(request.webhookUrl()) ? null : request.webhookUrl().trim());
        config.setHttpMethod(request.method() == null ? DdnsConfig.HttpMethod.GET : request.method());
        if (!blank(request.headersJson())) config.setHeadersJson(encrypt(request.headersJson().trim())); else if (!preserveSecrets) config.setHeadersJson(null);
        if (!blank(request.bodyTemplate()) || !preserveSecrets) config.setBodyTemplate(request.bodyTemplate());
        if (!blank(request.credentialOne())) config.setCredentialOne(encrypt(request.credentialOne().trim())); else if (!preserveSecrets) config.setCredentialOne(null);
        if (!blank(request.credentialTwo())) config.setCredentialTwo(encrypt(request.credentialTwo().trim())); else if (!preserveSecrets) config.setCredentialTwo(null);
        config.setEnabled(request.enabled()); config.setIpv4Enabled(request.ipv4Enabled()); config.setIpv6Enabled(request.ipv6Enabled()); config.setMaxRetries(request.maxRetries() == null ? 3 : request.maxRetries());
    }

    private void validate(DdnsDtos.Request request) {
        if (request == null || request.name() == null || request.name().isBlank() || request.name().trim().length() > 100 || request.provider() == null
                || request.domains() == null || request.domains().isEmpty() || (!request.ipv4Enabled() && !request.ipv6Enabled())) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "DDNS 域名或地址类型配置无效");
        }
        List<String> normalizedDomains = normalizeDomains(request.domains());
        if (normalizedDomains.isEmpty() || String.join(",", normalizedDomains).length() > 1000) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "DDNS 域名配置过长或无效");
        }
        if (request.provider() == DdnsConfig.Provider.WEBHOOK && blank(request.webhookUrl())) throw new ApiException(HttpStatus.BAD_REQUEST, "Webhook DDNS 必须填写 URL");
        if (!blank(request.webhookUrl())) try { URI uri = URI.create(request.webhookUrl()); if (!List.of("http", "https").contains(uri.getScheme()) || uri.getHost() == null) throw new IllegalArgumentException(); } catch (Exception exception) { throw new ApiException(HttpStatus.BAD_REQUEST, "Webhook URL 无效"); }
        if (!blank(request.headersJson())) try { mapper.readValue(request.headersJson(), HEADERS); } catch (Exception exception) { throw new ApiException(HttpStatus.BAD_REQUEST, "Webhook 请求头必须是扁平 JSON"); }
        if (!secrets.available() && (!blank(request.credentialOne()) || !blank(request.credentialTwo()) || !blank(request.headersJson()))) throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "未配置设置加密密钥，无法保存 DDNS 凭据");
    }

    private List<String> normalizeDomains(List<String> values) {
        return values.stream().map(value -> value == null ? "" : value.trim()).filter(value -> !value.isBlank()).distinct().peek(value -> {
            if (value.length() > 253 || value.contains("/") || value.contains("\\") || value.chars().anyMatch(Character::isWhitespace)
                    || value.startsWith(".") || value.endsWith(".") || !value.matches("[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?")) {
                throw new ApiException(HttpStatus.BAD_REQUEST, "DDNS 域名格式无效");
            }
        }).toList();
    }

    private String normalizeIp(String value) {
        if (blank(value)) throw new ApiException(HttpStatus.BAD_REQUEST, "测试 IP 不能为空");
        String candidate = value.trim();
        if (!candidate.matches("[0-9a-fA-F:.%]+")) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "测试 IP 地址无效");
        }
        try {
            return InetAddress.getByName(candidate).getHostAddress();
        } catch (Exception exception) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "测试 IP 地址无效");
        }
    }

    private DdnsConfig require(Long id) { return configs.findById(id).orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "DDNS 配置不存在")); }
    private DdnsDtos.View view(DdnsConfig config) { return view(config, true); }
    private DdnsDtos.View view(DdnsConfig config, boolean includeErrorDetails) { return new DdnsDtos.View(config.getId(), config.getName(), config.getProvider(), domains(config.getDomains()), !blank(config.getWebhookUrl()), config.getHttpMethod(), config.isEnabled(), config.isIpv4Enabled(), config.isIpv6Enabled(), config.getMaxRetries(), config.getLastStatus(), includeErrorDetails ? config.getLastError() : null, config.getLastUpdatedAt(), !blank(config.getCredentialOne()), !blank(config.getCredentialTwo())); }
    private List<String> domains(String value) { return value == null ? List.of() : List.of(value.split(",")).stream().map(String::trim).filter(item -> !item.isBlank()).toList(); }
    private Map<String, String> parseHeaders(String value) { if (blank(value)) return Map.of(); try { return mapper.readValue(decrypt(value), HEADERS); } catch (Exception ignored) { return Map.of(); } }
    private String expand(String value, String domain, String ip, String type, String record, DdnsConfig config) { if (value == null) return ""; return value.replace("#ip#", ip).replace("#domain#", domain).replace("#type#", type).replace("#record#", record).replace("#access_id#", decrypt(config.getCredentialOne())).replace("#access_secret#", decrypt(config.getCredentialTwo())); }
    private String encrypt(String value) { return secrets.encrypt(value); }
    private String decrypt(String value) { return blank(value) ? "" : (value.startsWith("v1:") ? secrets.decrypt(value) : value); }
    private boolean isIpv6(String ip) { try { return InetAddress.getByName(ip).getHostAddress().contains(":"); } catch (Exception ignored) { return ip.contains(":"); } }
    private String truncate(String value) { if (value == null) return "更新失败"; return value.length() > 500 ? value.substring(0, 500) : value; }
    private boolean blank(String value) { return value == null || value.isBlank(); }

    private static SimpleClientHttpRequestFactory requestFactory() {
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout(Duration.ofSeconds(5));
        factory.setReadTimeout(Duration.ofSeconds(10));
        return factory;
    }
}
