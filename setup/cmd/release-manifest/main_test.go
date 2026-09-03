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
	if err := run("v"+version, root, output, "v1.20.0", "2026-09-04T00:00:00+08:00"); err != nil {
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
	}
}

func TestRunRejectsMissingPlatformAsset(t *testing.T) {
	err := run("v1.20.11", t.TempDir(), filepath.Join(t.TempDir(), "manifest.json"), "v1.20.0", "2026-09-04T00:00:00Z")
	if err == nil {
		t.Fatal("missing release assets were accepted")
	}
}
