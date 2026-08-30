package com.guanlan.monitor.service;

import com.guanlan.monitor.api.ApiException;
import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import org.springframework.web.client.RestClient;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class NotificationServiceTest {
    private HttpServer server;

    @AfterEach
    void stopServer() {
        if (server != null) server.stop(0);
    }

    @Test
    void acceptsSuccessfulDingTalkResponse() throws IOException {
        NotificationService service = service("{\"errcode\":0,\"errmsg\":\"ok\"}", "dingtalk");

        assertThat(service.test("dingtalk").message()).isEqualTo("测试通知已发送");
    }

    @Test
    void reportsDingTalkQuotaExhaustion() throws IOException {
        NotificationService service = service("{\"errcode\":90030,\"errmsg\":\"quota exceeded\"}", "dingtalk");

        assertThatThrownBy(() -> service.test("dingtalk"))
                .isInstanceOfSatisfying(ApiException.class, exception -> {
                    assertThat(exception.getStatus()).isEqualTo(HttpStatus.BAD_GATEWAY);
                    assertThat(exception.getMessage()).contains("调用额度已用尽");
                });
    }

    @Test
    void reportsProviderBusinessErrorEvenWithHttpSuccess() throws IOException {
        NotificationService service = service("{\"errcode\":310000,\"errmsg\":\"keywords not in content\"}", "dingtalk");

        assertThatThrownBy(() -> service.test("dingtalk"))
                .isInstanceOfSatisfying(ApiException.class, exception -> {
                    assertThat(exception.getStatus()).isEqualTo(HttpStatus.BAD_GATEWAY);
                    assertThat(exception.getMessage()).contains("错误码 310000", "keywords not in content");
                });
    }

    @Test
    void acceptsSuccessfulWeComResponse() throws IOException {
        NotificationService service = service("{\"errcode\":0,\"errmsg\":\"ok\"}", "wecom");

        assertThat(service.test("wecom").message()).isEqualTo("测试通知已发送");
    }

    @Test
    void addsKeywordAndSignatureForDingTalk() throws IOException {
        AtomicReference<String> requestUri = new AtomicReference<>();
        AtomicReference<String> requestBody = new AtomicReference<>();
        NotificationService service = serviceWithRuntime(
                new SettingService.WebhookRuntime(true, endpoint(), "DATABASE", "监控", "secret"),
                new SettingService.WebhookRuntime(false, endpoint(), "DATABASE"), requestUri, requestBody);

        service.test("dingtalk");

        assertThat(requestUri.get()).contains("timestamp=", "sign=");
        assertThat(requestBody.get()).contains("监控");
    }

    @Test
    void sendsGenericJsonPayload() throws IOException {
        AtomicReference<String> requestBody = new AtomicReference<>();
        NotificationService service = genericService("GENERIC_JSON", requestBody);

        assertThat(service.test("generic").message()).isEqualTo("测试通知已发送");
        assertThat(requestBody.get()).contains("\"text\":\"[观澜监控] 通知通道测试成功\"");
    }

    @Test
    void sendsPlainTextPayload() throws IOException {
        AtomicReference<String> requestBody = new AtomicReference<>();
        NotificationService service = genericService("PLAIN_TEXT", requestBody);

        service.test("generic");

        assertThat(requestBody.get()).isEqualTo("[观澜监控] 通知通道测试成功");
    }

    private NotificationService service(String response, String enabledChannel) throws IOException {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/webhook", exchange -> {
            exchange.getRequestBody().readAllBytes();
            byte[] body = response.getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, body.length);
            exchange.getResponseBody().write(body);
            exchange.close();
        });
        server.start();

        String url = "http://127.0.0.1:" + server.getAddress().getPort() + "/webhook";
        SettingService settings = mock(SettingService.class);
        AuditService audit = mock(AuditService.class);
        SettingService.WebhookRuntime dingtalk = new SettingService.WebhookRuntime("dingtalk".equals(enabledChannel), url, "DATABASE");
        SettingService.WebhookRuntime wecom = new SettingService.WebhookRuntime("wecom".equals(enabledChannel), url, "DATABASE");
        SettingService.EmailRuntime email = new SettingService.EmailRuntime(false, "", 587, "", "", "", "", true, true, "NONE");
        when(settings.notificationRuntime()).thenReturn(new SettingService.NotificationRuntime(email, dingtalk, wecom));
        when(settings.publicBrand()).thenReturn(new SettingService.PublicBrandView("观澜监控", "/favicon.svg"));

        return new NotificationService(settings, audit, RestClient.builder());
    }

    private NotificationService serviceWithRuntime(SettingService.WebhookRuntime dingtalk,
                                                    SettingService.WebhookRuntime wecom,
                                                    AtomicReference<String> requestUri,
                                                    AtomicReference<String> requestBody) throws IOException {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/webhook", exchange -> {
            requestUri.set(exchange.getRequestURI().toString());
            requestBody.set(new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8));
            byte[] body = "{\"errcode\":0,\"errmsg\":\"ok\"}".getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, body.length);
            exchange.getResponseBody().write(body);
            exchange.close();
        });
        server.start();
        String url = "http://127.0.0.1:" + server.getAddress().getPort() + "/webhook";
        SettingService settings = mock(SettingService.class);
        AuditService audit = mock(AuditService.class);
        SettingService.EmailRuntime email = new SettingService.EmailRuntime(false, "", 587, "", "", "", "", true, true, "NONE");
        when(settings.notificationRuntime()).thenReturn(new SettingService.NotificationRuntime(email,
                new SettingService.WebhookRuntime(true, url, dingtalk.source(), dingtalk.keyword(), dingtalk.signSecret()),
                new SettingService.WebhookRuntime(false, url, wecom.source())));
        when(settings.publicBrand()).thenReturn(new SettingService.PublicBrandView("观澜监控", "/favicon.svg"));
        return new NotificationService(settings, audit, RestClient.builder());
    }

    private String endpoint() { return "http://127.0.0.1:1/webhook"; }

    private NotificationService genericService(String format, AtomicReference<String> requestBody) throws IOException {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/webhook", exchange -> {
            requestBody.set(new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8));
            byte[] body = "accepted".getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(202, body.length);
            exchange.getResponseBody().write(body);
            exchange.close();
        });
        server.start();
        String url = "http://127.0.0.1:" + server.getAddress().getPort() + "/webhook";
        SettingService settings = mock(SettingService.class);
        AuditService audit = mock(AuditService.class);
        SettingService.EmailRuntime email = new SettingService.EmailRuntime(false, "", 587, "", "", "", "", true, true, "NONE");
        SettingService.WebhookRuntime disabled = new SettingService.WebhookRuntime(false, url, "DATABASE");
        SettingService.WebhookRuntime generic = new SettingService.WebhookRuntime(true, url, "DATABASE", "", "", format);
        when(settings.notificationRuntime()).thenReturn(new SettingService.NotificationRuntime(email, disabled, disabled, generic));
        when(settings.publicBrand()).thenReturn(new SettingService.PublicBrandView("观澜监控", "/favicon.svg"));
        return new NotificationService(settings, audit, RestClient.builder());
    }
}
