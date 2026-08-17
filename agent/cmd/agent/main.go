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
		MonitoredServices:   cfg.MonitoredServices,
		SkipProcesses:       cfg.SkipProcesses,
		SkipConnectionCount: cfg.SkipConnectionCount,
		DiskMountpoints:     cfg.DiskMountpoints,
	})
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	logger.Info("agent started", "device_id", cfg.DeviceID, "interval", cfg.Interval.String())
	collectAndSend(ctx, logger, metrics, queue, client)
	ticker := time.NewTicker(cfg.Interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			logger.Info("agent stopped")
			return
		case <-ticker.C:
			collectAndSend(ctx, logger, metrics, queue, client)
		}
	}
}

func collectAndSend(ctx context.Context, logger *slog.Logger, metrics *collector.Collector, queue *spool.Queue, client *api.Client) {
	report, err := metrics.Collect(ctx)
	if err != nil {
		logger.Error("metric collection failed", "error", err)
		return
	}
	body, err := json.Marshal(report)
	if err != nil {
		logger.Error("metric encoding failed", "error", err)
		return
	}
	if err := queue.Enqueue(body); err != nil {
		logger.Error("report buffering failed", "error", err)
		return
	}

	paths, err := queue.List()
	if err != nil {
		logger.Error("report buffer listing failed", "error", err)
		return
	}
	for _, path := range paths {
		payload, readErr := os.ReadFile(path)
		if readErr != nil {
			logger.Warn("buffered report is unreadable", "error", readErr)
			continue
		}
		if sendErr := client.Send(ctx, payload); sendErr != nil {
			if !errors.Is(sendErr, context.Canceled) {
				logger.Warn("report delivery deferred", "error", sendErr, "buffered", len(paths))
			}
			return
		}
		if removeErr := queue.Remove(path); removeErr != nil {
			logger.Warn("sent report could not be removed from buffer", "error", removeErr)
			return
		}
	}
}
