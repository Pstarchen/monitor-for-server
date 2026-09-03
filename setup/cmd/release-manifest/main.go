package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

type manifest struct {
	SchemaVersion               int     `json:"schemaVersion"`
	Version                     string  `json:"version"`
	PublishedAt                 string  `json:"publishedAt"`
	MinimumCompatibleController string  `json:"minimumCompatibleControllerVersion"`
	Assets                      []asset `json:"assets"`
}

type asset struct {
	OS     string `json:"os"`
	Arch   string `json:"arch"`
	File   string `json:"file"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

var stableVersion = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+$`)

func main() {
	version := flag.String("version", "", "stable release version, including the v prefix")
	assetsDir := flag.String("assets", "", "directory containing release archives")
	output := flag.String("output", "", "manifest output path")
	minimumController := flag.String("minimum-controller", "v1.20.0", "minimum compatible controller version")
	publishedAt := flag.String("published-at", "", "RFC3339 publication time; defaults to current UTC time")
	flag.Parse()
	if err := run(*version, *assetsDir, *output, *minimumController, *publishedAt); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(version, assetsDir, output, minimumController, publishedAt string) error {
	if !stableVersion.MatchString(version) || !stableVersion.MatchString(minimumController) {
		return fmt.Errorf("version and minimum-controller must be stable semantic versions with a v prefix")
	}
	if strings.TrimSpace(assetsDir) == "" || strings.TrimSpace(output) == "" {
		return fmt.Errorf("assets and output are required")
	}
	if publishedAt == "" {
		publishedAt = time.Now().UTC().Format(time.RFC3339)
	} else if parsed, err := time.Parse(time.RFC3339, publishedAt); err != nil {
		return fmt.Errorf("published-at must be RFC3339: %w", err)
	} else {
		publishedAt = parsed.UTC().Format(time.RFC3339)
	}
	releaseVersion := strings.TrimPrefix(version, "v")
	targets := []struct {
		os, arch, extension string
	}{
		{"linux", "amd64", "tar.gz"},
		{"linux", "arm64", "tar.gz"},
		{"windows", "amd64", "zip"},
		{"windows", "arm64", "zip"},
	}
	result := manifest{
		SchemaVersion:               1,
		Version:                     version,
		PublishedAt:                 publishedAt,
		MinimumCompatibleController: minimumController,
		Assets:                      make([]asset, 0, len(targets)),
	}
	for _, target := range targets {
		name := fmt.Sprintf("xingchen-agent_%s_%s_%s.%s", releaseVersion, target.os, target.arch, target.extension)
		path := filepath.Join(assetsDir, name)
		digest, size, err := hashFile(path)
		if err != nil {
			return fmt.Errorf("read %s: %w", name, err)
		}
		result.Assets = append(result.Assets, asset{OS: target.os, Arch: target.arch, File: name, SHA256: digest, Size: size})
	}
	if err := os.MkdirAll(filepath.Dir(output), 0755); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(output), ".manifest-*")
	if err != nil {
		return err
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)
	encoder := json.NewEncoder(temporary)
	encoder.SetIndent("", "  ")
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(result); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryName, output)
}

func hashFile(path string) (string, int64, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer file.Close()
	hash := sha256.New()
	size, err := io.Copy(hash, file)
	if err != nil {
		return "", 0, err
	}
	if size <= 0 {
		return "", 0, fmt.Errorf("asset is empty")
	}
	return hex.EncodeToString(hash.Sum(nil)), size, nil
}
