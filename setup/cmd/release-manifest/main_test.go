package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestRunCreatesManifestForEverySupportedPlatform(t *testing.T) {
	root := t.TempDir()
	version := "1.20.11"
	for _, name := range []string{
		"xingchen-agent_" + version + "_linux_amd64.tar.gz",
		"xingchen-agent_" + version + "_linux_arm64.tar.gz",
		"xingchen-agent_" + version + "_windows_amd64.zip",
		"xingchen-agent_" + version + "_windows_arm64.zip",
	} {
		if err := os.WriteFile(filepath.Join(root, name), []byte(name), 0600); err != nil {
			t.Fatal(err)
		}
	}
	output := filepath.Join(root, "manifest.json")
	if err := run("v"+version, root, output, "v1.20.0", "2026-09-04T00:00:00+08:00", "https://releases.internal.example/xingchen"); err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	var result manifest
	if err := json.Unmarshal(content, &result); err != nil {
		t.Fatal(err)
	}
	if result.Version != "v1.20.11" || result.PublishedAt != "2026-09-03T16:00:00Z" || len(result.Assets) != 4 {
		t.Fatalf("manifest = %+v", result)
	}
	for _, item := range result.Assets {
		if item.Size <= 0 || len(item.SHA256) != 64 {
			t.Fatalf("invalid manifest asset: %+v", item)
		}
		wantURL := "https://releases.internal.example/xingchen/v1.20.11/" + item.File
		if item.URL != wantURL {
			t.Fatalf("asset URL = %q, want %q", item.URL, wantURL)
		}
	}
}

func TestRunRejectsMissingPlatformAsset(t *testing.T) {
	err := run("v1.20.11", t.TempDir(), filepath.Join(t.TempDir(), "manifest.json"), "v1.20.0", "2026-09-04T00:00:00Z", defaultArtifactBaseURL)
	if err == nil {
		t.Fatal("missing release assets were accepted")
	}
}

func TestRunRejectsNonCanonicalVersions(t *testing.T) {
	for _, version := range []string{"v01.20.11", "v1.020.11", "v1.20.011", "v1.20.11-rc.1"} {
		if err := run(version, t.TempDir(), filepath.Join(t.TempDir(), "manifest.json"), "v1.20.0", "2026-09-04T00:00:00Z", defaultArtifactBaseURL); err == nil {
			t.Fatalf("non-canonical release version was accepted: %q", version)
		}
	}
	if err := run("v1.20.11", t.TempDir(), filepath.Join(t.TempDir(), "manifest.json"), "v01.20.0", "2026-09-04T00:00:00Z", defaultArtifactBaseURL); err == nil {
		t.Fatal("non-canonical minimum controller version was accepted")
	}
}

func TestRunRejectsUnsafeArtifactBaseURL(t *testing.T) {
	for _, value := range []string{
		"",
		"http://releases.internal.example/xingchen",
		"https://user:secret@releases.internal.example/xingchen",
		"https://releases.internal.example/xingchen?token=secret",
		"https://releases.internal.example/xingchen#fragment",
		"https://releases.internal.example/xingchen/../private",
		"https://releases.internal.example/xingchen/%2e%2e/private",
	} {
		if _, err := normalizeArtifactBaseURL(value); err == nil {
			t.Fatalf("unsafe artifact base URL was accepted: %q", value)
		}
	}
}
