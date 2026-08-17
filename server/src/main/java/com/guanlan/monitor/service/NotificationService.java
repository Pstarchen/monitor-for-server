package com.guanlan.monitor.service;

import com.guanlan.monitor.config.AppProperties;
import com.guanlan.monitor.domain.AlertEvent;
import lombok.RequiredArgsConstructor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.mail.SimpleMailMessage;
import org.springframework.mail.javamail.JavaMailSender;
import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClient;

import java.util.Map;

@Service
@RequiredArgsConstructor
public class NotificationService {
    private static final Logger log = LoggerFactory.getLogger(NotificationService.class);
    private final JavaMailSender mailSender;
    private final AppProperties properties;
    private final RestClient restClient = RestClient.create();

    @Async
    public void send(AlertEvent event) {
        String text = "[观澜监控] " + event.getMessage();
        sendEmail(text);
        sendWebhook("钉钉", properties.getNotification().getDingtalkWebhookUrl(), text);
        sendWebhook("企业微信", properties.getNotification().getWecomWebhookUrl(), text);
    }

    private void sendEmail(String text) {
        String to = properties.getNotification().getEmailTo();
        String from = properties.getNotification().getEmailFrom();
        if (blank(to) || blank(from)) return;
        try {
            SimpleMailMessage message = new SimpleMailMessage();
            message.setFrom(from);
            message.setTo(to.split(","));
            message.setSubject("观澜监控告警");
            message.setText(text);
            mailSender.send(message);
        } catch (Exception exception) {
            log.warn("Email notification failed: {}", exception.getClass().getSimpleName());
        }
    }

    private void sendWebhook(String channel, String url, String text) {
        if (blank(url)) return;
        try {
            restClient.post().uri(url).body(Map.of("msgtype", "text", "text", Map.of("content", text))).retrieve().toBodilessEntity();
        } catch (Exception exception) {
            log.warn("{} notification failed: {}", channel, exception.getClass().getSimpleName());
        }
    }

    private boolean blank(String value) { return value == null || value.isBlank(); }
}

