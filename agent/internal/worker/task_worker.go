package worker

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"xingchen-monitor/agent/internal/api"
	"xingchen-monitor/agent/internal/executor"
	"xingchen-monitor/agent/internal/model"
)

func Run(ctx context.Context, logger *slog.Logger, client *api.Client, pollInterval time.Duration, maxOutputBytes int, allowCommandExecution bool, allowFileOperations bool, hostRoot string) {
	timer := time.NewTimer(0)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}

		task, err := client.PollTask(ctx)
		if err != nil {
			if ctx.Err() == nil {
				logger.Warn("task poll failed", "error", err)
			}
			timer.Reset(pollInterval)
			continue
		}
		if task == nil {
			timer.Reset(pollInterval)
			continue
		}
		result := executor.Run(ctx, *task, maxOutputBytes, allowCommandExecution, allowFileOperations, hostRoot)
		taskResult := model.TaskResult{
			Status: result.Status, ExitCode: result.ExitCode, Stdout: result.Stdout, Stderr: result.Stderr, Error: result.Error,
		}
		if err := sendTaskResult(ctx, client, task.ID, taskResult); err != nil {
			logger.Warn("task result delivery failed", "task_id", task.ID, "error", err)
		} else {
			logger.Info("task completed", "task_id", task.ID, "status", result.Status)
		}
		timer.Reset(pollInterval)
	}
}

func sendTaskResult(ctx context.Context, client *api.Client, taskID int64, result model.TaskResult) error {
	const attempts = 4
	backoff := 250 * time.Millisecond
	var lastErr error
	for attempt := 0; attempt < attempts; attempt++ {
		lastErr = client.SendTaskResult(ctx, taskID, result)
		if lastErr == nil {
			return nil
		}
		var statusErr *api.HTTPStatusError
		if errors.As(lastErr, &statusErr) && statusErr.StatusCode >= 400 && statusErr.StatusCode < 500 && statusErr.StatusCode != 429 {
			return lastErr
		}
		if attempt == attempts-1 {
			break
		}
		timer := time.NewTimer(backoff)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
		backoff *= 2
	}
	return lastErr
}
