package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"guanlan-monitor/agent/internal/api"
	"guanlan-monitor/agent/internal/collector"
	"guanlan-monitor/agent/internal/config"
	"guanlan-monitor/agent/internal/spool"
	"guanlan-monitor/agent/internal/worker"
)

func main() {
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
		IntegrityPaths:           cfg.IntegrityPaths,
	})
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	logger.Info("agent started", "device_id", cfg.DeviceID, "interval", cfg.Interval.String())
	if cfg.AllowCommandExecution || cfg.AllowFileOperations {
		go worker.Run(ctx, logger, client, cfg.CommandPollInterval, cfg.MaxCommandOutputBytes, cfg.AllowCommandExecution, cfg.AllowFileOperations, cfg.HostRoot)
	} else {
		logger.Info("remote task execution disabled")
	}
	interval := cfg.Interval
	if updated := collectAndSend(ctx, logger, metrics, queue, client); updated > 0 {
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
			if updated := collectAndSend(ctx, logger, metrics, queue, client); updated > 0 && updated != interval {
				logger.Info("report interval updated", "interval", updated.String())
				interval = updated
			}
			timer.Reset(interval)
		}
	}
}

func collectAndSend(ctx context.Context, logger *slog.Logger, metrics *collector.Collector, queue *spool.Queue, client *api.Client) time.Duration {
	report, err := metrics.Collect(ctx)
	if err != nil {
		logger.Error("metric collection failed", "error", err)
		return 0
	}
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

	paths, err := queue.List()
	if err != nil {
		logger.Error("report buffer listing failed", "error", err)
		return updatedInterval
	}
	for _, path := range paths {
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
