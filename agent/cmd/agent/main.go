package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"xingchen-monitor/agent/internal/api"
	"xingchen-monitor/agent/internal/collector"
	"xingchen-monitor/agent/internal/config"
	"xingchen-monitor/agent/internal/model"
	"xingchen-monitor/agent/internal/spool"
	"xingchen-monitor/agent/internal/worker"
)

var version = "dev"

const (
	maxReplayReportsPerCycle = 10
	replayBudget             = 5 * time.Second
	maxUpdateStatusFileBytes = 4 << 10
	maxAgentVersionLength    = 80
	maxUpdateErrorLength     = 500
)

func main() {
	if len(os.Args) > 1 && (os.Args[1] == "--version" || os.Args[1] == "-version" || os.Args[1] == "version") {
		fmt.Println(version)
		return
	}
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	cfg, err := config.Load(os.Args[1:])
	if err != nil {
		logger.Error("invalid configuration", "error", err)
		os.Exit(2)
	}

	queue, err := spool.New(cfg.SpoolDir, cfg.MaxBufferedReports)
	if err != nil {
		logger.Error("cannot initialize report buffer", "error", err)
		os.Exit(1)
	}

	client := api.NewClient(cfg.ServerURL, cfg.DeviceID, cfg.AgentKey, cfg.RequestTimeout)
	metrics := collector.New(collector.Options{
		MonitoredServices:        cfg.MonitoredServices,
		MonitoredProcesses:       cfg.MonitoredProcesses,
		SkipProcesses:            cfg.SkipProcesses,
		CollectAllProcesses:      cfg.CollectAllProcesses,
		ProcessCollectionLimit:   cfg.ProcessCollectionLimit,
		SkipConnectionCount:      cfg.SkipConnectionCount,
		SkipPortCollection:       cfg.SkipPortCollection,
		PortCollectionLimit:      cfg.PortCollectionLimit,
		SkipContainerCollection:  cfg.SkipContainerCollection,
		ContainerCollectionLimit: cfg.ContainerCollectionLimit,
		DiskMountpoints:          cfg.DiskMountpoints,
		HostRoot:                 cfg.HostRoot,
		DockerSocket:             cfg.DockerSocket,
		LogPaths:                 cfg.LogPaths,
		CollectSystemLogs:        cfg.CollectSystemLogs,
		IntegrityPaths:           cfg.IntegrityPaths,
		CustomMetrics:            customMetricOptions(cfg.CustomMetrics),
	})
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	logger.Info("agent started", "device_id", cfg.DeviceID, "interval", cfg.Interval.String())
	if cfg.AllowCommandExecution || cfg.AllowFileOperations || cfg.UpdateRequestPath != "" {
		go worker.Run(ctx, logger, client, cfg.CommandPollInterval, cfg.MaxCommandOutputBytes, cfg.AllowCommandExecution, cfg.AllowFileOperations, cfg.HostRoot, cfg.UpdateRequestPath, cfg.UpdateLauncherPath)
	} else {
		logger.Info("remote task execution disabled")
	}
	interval := cfg.Interval
	if updated := collectAndSendWithAgentInfo(ctx, logger, metrics, queue, client, version, cfg.UpdateStatusPath); updated > 0 {
		interval = updated
	}
	timer := time.NewTimer(interval)
	defer timer.Stop()

	for {
		select {
		case <-ctx.Done():
			logger.Info("agent stopped")
			return
		case <-timer.C:
			if updated := collectAndSendWithAgentInfo(ctx, logger, metrics, queue, client, version, cfg.UpdateStatusPath); updated > 0 && updated != interval {
				logger.Info("report interval updated", "interval", updated.String())
				interval = updated
			}
			timer.Reset(interval)
		}
	}
}

func customMetricOptions(values []config.CustomMetric) []collector.CustomMetricConfig {
	result := make([]collector.CustomMetricConfig, 0, len(values))
	for _, value := range values {
		result = append(result, collector.CustomMetricConfig{Name: value.Name, Command: value.Command, Args: value.Args, Kind: value.Kind})
	}
	return result
}

func collectAndSend(ctx context.Context, logger *slog.Logger, metrics *collector.Collector, queue *spool.Queue, client *api.Client) time.Duration {
	return collectAndSendWithAgentInfo(ctx, logger, metrics, queue, client, version, "")
}

func collectAndSendWithAgentInfo(ctx context.Context, logger *slog.Logger, metrics *collector.Collector, queue *spool.Queue, client *api.Client, agentVersion, updateStatusPath string) time.Duration {
	report, err := metrics.Collect(ctx)
	if err != nil {
		logger.Error("metric collection failed", "error", err)
		return 0
	}
	report.Agent = readAgentInfo(agentVersion, updateStatusPath)
	body, err := json.Marshal(report)
	if err != nil {
		logger.Error("metric encoding failed", "error", err)
		return 0
	}
	if err := queue.Enqueue(body); err != nil {
		logger.Error("report buffering failed", "error", err)
		return 0
	}
	var updatedInterval time.Duration

	paths, err := queue.ListForDelivery()
	if err != nil {
		logger.Error("report buffer listing failed", "error", err)
		return updatedInterval
	}
	deliveryStarted := time.Now()
	for index, path := range paths {
		if index > maxReplayReportsPerCycle || (index > 1 && time.Since(deliveryStarted) >= replayBudget) {
			break
		}
		payload, readErr := os.ReadFile(path)
		if readErr != nil {
			logger.Warn("buffered report is unreadable", "error", readErr)
			continue
		}
		newInterval, sendErr := client.SendWithInterval(ctx, payload)
		if sendErr != nil {
			if !errors.Is(sendErr, context.Canceled) {
				logger.Warn("report delivery deferred", "error", sendErr, "buffered", len(paths))
			}
			return updatedInterval
		}
		if newInterval > 0 {
			updatedInterval = newInterval
		}
		if removeErr := queue.Remove(path); removeErr != nil {
			logger.Warn("sent report could not be removed from buffer", "error", removeErr)
			return updatedInterval
		}
	}
	return updatedInterval
}

type updateStatusFile struct {
	Status    model.AgentUpdateStatus `json:"status"`
	LastError string                  `json:"lastError"`
	ChangedAt string                  `json:"changedAt"`
}

func readAgentInfo(agentVersion, updateStatusPath string) *model.AgentInfo {
	fallback := &model.AgentInfo{
		Version:      normalizedVersion(agentVersion),
		UpdateStatus: model.AgentUpdateIdle,
	}
	file, err := os.Open(updateStatusPath)
	if err != nil {
		return fallback
	}
	defer file.Close()

	raw, err := io.ReadAll(io.LimitReader(file, maxUpdateStatusFileBytes+1))
	if err != nil || len(raw) > maxUpdateStatusFileBytes {
		return fallback
	}
	var state updateStatusFile
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&state); err != nil {
		return fallback
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return fallback
	}
	state.LastError = strings.TrimSpace(state.LastError)
	if !validUpdateStatus(state.Status) || len([]rune(state.LastError)) > maxUpdateErrorLength {
		return fallback
	}
	changedAt, err := time.Parse(time.RFC3339, strings.TrimSpace(state.ChangedAt))
	if err != nil {
		return fallback
	}
	changedAt = changedAt.UTC()
	return &model.AgentInfo{
		Version:              fallback.Version,
		UpdateStatus:         state.Status,
		LastUpdateError:      state.LastError,
		UpdateStateChangedAt: &changedAt,
	}
}

func normalizedVersion(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return "dev"
	}
	runes := []rune(value)
	if len(runes) > maxAgentVersionLength {
		return string(runes[:maxAgentVersionLength])
	}
	return value
}

func validUpdateStatus(status model.AgentUpdateStatus) bool {
	switch status {
	case model.AgentUpdateIdle, model.AgentUpdateChecking, model.AgentUpdateDownloading,
		model.AgentUpdateApplying, model.AgentUpdateSucceeded, model.AgentUpdateFailed,
		model.AgentUpdatePaused, model.AgentUpdateRollingBack:
		return true
	default:
		return false
	}
}
