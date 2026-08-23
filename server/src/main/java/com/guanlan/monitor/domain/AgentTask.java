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
@Table(name = "agent_tasks", indexes = {
        @Index(name = "idx_agent_tasks_device_status_created", columnList = "device_id,status,created_at"),
        @Index(name = "idx_agent_tasks_status_created", columnList = "status,created_at")
})
public class AgentTask {
    public enum Status { QUEUED, RUNNING, SUCCEEDED, FAILED, TIMED_OUT, CANCELED }
    public enum Operation { COMMAND, FILE_LIST, FILE_READ, FILE_WRITE, FILE_DELETE }

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "device_id", nullable = false)
    private Device device;

    @Column(nullable = false, length = 128)
    private String command;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    private Operation operation = Operation.COMMAND;

    @Column(name = "args_json", nullable = false, columnDefinition = "TEXT")
    private String argsJson;

    @Column(name = "payload_json", columnDefinition = "TEXT")
    private String payloadJson;

    @Column(name = "timeout_seconds", nullable = false)
    private int timeoutSeconds;

    @Column(name = "max_output_bytes", nullable = false)
    private int maxOutputBytes;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    private Status status = Status.QUEUED;

    @Column(name = "created_by", nullable = false, length = 64)
    private String createdBy;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "started_at")
    private Instant startedAt;

    @Column(name = "finished_at")
    private Instant finishedAt;

    @Column(name = "exit_code")
    private Integer exitCode;

    @Column(columnDefinition = "TEXT")
    private String stdout;

    @Column(columnDefinition = "TEXT")
    private String stderr;

    @Column(length = 500)
    private String error;

    @PrePersist
    void onCreate() { createdAt = Instant.now(); }
}
