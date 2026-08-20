package com.guanlan.monitor.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.guanlan.monitor.api.ApiException;
import com.guanlan.monitor.config.AppProperties;
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

class ControllerUpdateServiceTest {
    private HttpServer server;

    @AfterEach
    void stopServer() {
        if (server != null) server.stop(0);
    }

    @Test
    void proxiesStatusWithInternalToken() throws IOException {
        AtomicReference<String> receivedToken = new AtomicReference<>();
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/internal/controller-update/status", exchange -> {
            receivedToken.set(exchange.getRequestHeaders().getFirst("X-Controller-Update-Token"));
            byte[] response = "{\"state\":\"IDLE\",\"currentRevision\":\"abc123\"}".getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, response.length);
            exchange.getResponseBody().write(response);
            exchange.close();
        });
        server.start();

        AppProperties properties = properties("internal-token");
        ControllerUpdateService service = new ControllerUpdateService(properties, new ObjectMapper(), RestClient.builder());

        assertThat(service.status().path("currentRevision").asText()).isEqualTo("abc123");
        assertThat(receivedToken.get()).isEqualTo("internal-token");
    }

    @Test
    void refusesRequestsWhenInternalTokenIsMissing() {
        AppProperties properties = properties("");
        ControllerUpdateService service = new ControllerUpdateService(properties, new ObjectMapper(), RestClient.builder());

        assertThatThrownBy(service::status)
                .isInstanceOfSatisfying(ApiException.class, exception -> {
                    assertThat(exception.getStatus()).isEqualTo(HttpStatus.SERVICE_UNAVAILABLE);
                    assertThat(exception.getMessage()).isEqualTo("系统更新服务尚未配置");
                });
    }

    private AppProperties properties(String token) {
        AppProperties properties = new AppProperties();
        properties.getControllerUpdate().setServiceUrl("http://127.0.0.1:" + (server == null ? 1 : server.getAddress().getPort()));
        properties.getControllerUpdate().setToken(token);
        return properties;
    }
}
