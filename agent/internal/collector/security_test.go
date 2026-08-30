package collector

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRedactCronCommand(t *testing.T) {
	got := redactCronCommand("curl -H token=abc123 password=hunter2 --password hunter3 -p hunter4 --url https://example.test")
	if strings.Contains(got, "abc123") || strings.Contains(got, "hunter2") || strings.Contains(got, "hunter3") || strings.Contains(got, "hunter4") {
		t.Fatalf("secret was not redacted: %q", got)
	}
	if !strings.Contains(got, "token=***") || !strings.Contains(got, "password=***") || !strings.Contains(got, "--password ***") || !strings.Contains(got, "-p ***") {
		t.Fatalf("expected redacted markers: %q", got)
	}
}

func TestParseWindowsTasks(t *testing.T) {
	rows := `"\\Backup","2026-08-31 04:15:00","Ready"
"\\Deploy, nightly","N/A","Disabled"`
	got := parseWindowsTasks(rows)
	if len(got) != 2 || got[0].Command != `\\Backup` || got[0].Schedule != "2026-08-31 04:15:00" {
		t.Fatalf("unexpected tasks: %#v", got)
	}
	if got[1].Command != `\\Deploy, nightly` {
		t.Fatalf("CSV quoting was not preserved: %#v", got[1])
	}
}

func TestTailLines(t *testing.T) {
	got := tailLines("one\ntwo\nthree\n", 2)
	if strings.Join(got, "|") != "two|three" {
		t.Fatalf("unexpected tail: %#v", got)
	}
}

func TestCollectLogsAndIntegrityRejectRelativePaths(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "sample.log")
	if err := os.WriteFile(path, []byte("first\nlast\n"), 0600); err != nil {
		t.Fatal(err)
	}
	logs := collectLogs(context.Background(), []string{path, "relative.log"}, "")
	if len(logs) != 1 || len(logs[0].Lines) != 2 || logs[0].Lines[1] != "last" {
		t.Fatalf("unexpected logs: %#v", logs)
	}
	integrity := collectIntegrity(context.Background(), []string{path, "relative.log"}, "")
	if len(integrity) != 1 || len(integrity[0].SHA256) != 64 {
		t.Fatalf("unexpected integrity result: %#v", integrity)
	}
}
