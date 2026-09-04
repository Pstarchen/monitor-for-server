package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"xingchen-monitor/agent/internal/model"
)

func TestReadAgentInfoAcceptsUpdaterStatus(t *testing.T) {
	path := filepath.Join(t.TempDir(), "update-status.json")
	if err := os.WriteFile(path, []byte(`{"status":"FAILED","lastError":"health check failed","changedAt":"2026-09-04T08:09:10+08:00"}`), 0o600); err != nil {
		t.Fatal(err)
	}

	info := readAgentInfo(" v1.20.14 ", path)
	if info.Version != "v1.20.14" || info.UpdateStatus != model.AgentUpdateFailed || info.LastUpdateError != "health check failed" {
		t.Fatalf("unexpected agent info: %+v", info)
	}
	wantChangedAt := time.Date(2026, 9, 4, 0, 9, 10, 0, time.UTC)
	if info.UpdateStateChangedAt == nil || !info.UpdateStateChangedAt.Equal(wantChangedAt) {
		t.Fatalf("unexpected changed time: %v", info.UpdateStateChangedAt)
	}
}

func TestReadAgentInfoAcceptsEveryKnownStatus(t *testing.T) {
	statuses := []model.AgentUpdateStatus{
		model.AgentUpdateIdle,
		model.AgentUpdateChecking,
		model.AgentUpdateDownloading,
		model.AgentUpdateApplying,
		model.AgentUpdateSucceeded,
		model.AgentUpdateFailed,
		model.AgentUpdatePaused,
		model.AgentUpdateRollingBack,
	}
	for _, status := range statuses {
		t.Run(string(status), func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "update-status.json")
			body := `{"status":"` + string(status) + `","lastError":"","changedAt":"2026-09-04T00:00:00Z"}`
			if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
				t.Fatal(err)
			}
			if got := readAgentInfo("v1.20.14", path).UpdateStatus; got != status {
				t.Fatalf("status = %q, want %q", got, status)
			}
		})
	}
}

func TestReadAgentInfoFallsBackWithoutLeakingInvalidContent(t *testing.T) {
	cases := map[string]string{
		"malformed":         `{"status":"FAILED","lastError":"private-token"`,
		"unknown field":     `{"status":"IDLE","lastError":"","changedAt":"2026-09-04T00:00:00Z","detail":"private-token"}`,
		"unknown status":    `{"status":"RETRYING","lastError":"private-token","changedAt":"2026-09-04T00:00:00Z"}`,
		"invalid timestamp": `{"status":"FAILED","lastError":"private-token","changedAt":"yesterday"}`,
		"long error":        `{"status":"FAILED","lastError":"` + strings.Repeat("x", maxUpdateErrorLength+1) + `","changedAt":"2026-09-04T00:00:00Z"}`,
		"oversized file":    strings.Repeat("x", maxUpdateStatusFileBytes+1),
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "update-status.json")
			if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
				t.Fatal(err)
			}
			info := readAgentInfo("v1.20.14", path)
			if info.UpdateStatus != model.AgentUpdateIdle || info.LastUpdateError != "" || info.UpdateStateChangedAt != nil {
				t.Fatalf("invalid content escaped fallback: %+v", info)
			}
		})
	}

	info := readAgentInfo("", filepath.Join(t.TempDir(), "missing.json"))
	if info.Version != "dev" || info.UpdateStatus != model.AgentUpdateIdle {
		t.Fatalf("unexpected missing-file fallback: %+v", info)
	}
}
