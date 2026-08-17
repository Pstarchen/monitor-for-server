package config

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type Config struct {
	ServerURL           string
	DeviceID            string
	AgentKey            string
	Interval            time.Duration
	RequestTimeout      time.Duration
	SpoolDir            string
	MaxBufferedReports  int
	AllowInsecureHTTP   bool
	MonitoredServices   []string
	SkipProcesses       bool
	SkipConnectionCount bool
	DiskMountpoints     []string
}

type fileConfig struct {
	ServerURL           string   `json:"server_url"`
	DeviceID            string   `json:"device_id"`
	AgentKey            string   `json:"agent_key"`
	Interval            string   `json:"interval"`
	RequestTimeout      string   `json:"request_timeout"`
	SpoolDir            string   `json:"spool_dir"`
	MaxBufferedReports  int      `json:"max_buffered_reports"`
	AllowInsecureHTTP   bool     `json:"allow_insecure_http"`
	MonitoredServices   []string `json:"monitored_services"`
	SkipProcesses       bool     `json:"skip_process_collection"`
	SkipConnectionCount bool     `json:"skip_connection_count"`
	DiskMountpoints     []string `json:"disk_mountpoints"`
}

func Load(args []string) (Config, error) {
	flags := flag.NewFlagSet("guanlan-agent", flag.ContinueOnError)
	configPath := flags.String("config", env("GUANLAN_AGENT_CONFIG", "agent.json"), "path to JSON configuration")
	if err := flags.Parse(args); err != nil {
		return Config{}, err
	}

	raw, err := os.ReadFile(filepath.Clean(*configPath))
	if err != nil {
		return Config{}, fmt.Errorf("read config: %w", err)
	}
	var file fileConfig
	if err := json.Unmarshal(raw, &file); err != nil {
		return Config{}, fmt.Errorf("parse config: %w", err)
	}

	interval, err := parseDuration(file.Interval, 3*time.Second)
	if err != nil {
		return Config{}, fmt.Errorf("interval: %w", err)
	}
	timeout, err := parseDuration(file.RequestTimeout, 10*time.Second)
	if err != nil {
		return Config{}, fmt.Errorf("request_timeout: %w", err)
	}
	spoolDir := file.SpoolDir
	if spoolDir == "" {
		spoolDir = filepath.Join(filepath.Dir(*configPath), "data", "spool")
	}
	maxBuffered := file.MaxBufferedReports
	if maxBuffered <= 0 {
		maxBuffered = 10000
	}

	cfg := Config{
		ServerURL:           strings.TrimRight(strings.TrimSpace(file.ServerURL), "/"),
		DeviceID:            strings.TrimSpace(file.DeviceID),
		AgentKey:            strings.TrimSpace(file.AgentKey),
		Interval:            interval,
		RequestTimeout:      timeout,
		SpoolDir:            spoolDir,
		MaxBufferedReports:  maxBuffered,
		AllowInsecureHTTP:   file.AllowInsecureHTTP,
		MonitoredServices:   file.MonitoredServices,
		SkipProcesses:       file.SkipProcesses,
		SkipConnectionCount: file.SkipConnectionCount,
		DiskMountpoints:     cleanList(file.DiskMountpoints),
	}
	return cfg, cfg.Validate()
}

func cleanList(values []string) []string {
	result := make([]string, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}

func (c Config) Validate() error {
	if c.ServerURL == "" || c.DeviceID == "" || c.AgentKey == "" {
		return errors.New("server_url, device_id and agent_key are required")
	}
	parsed, err := url.Parse(c.ServerURL)
	if err != nil || parsed.Host == "" {
		return errors.New("server_url must be an absolute URL")
	}
	if parsed.Scheme != "https" {
		isLocal := parsed.Scheme == "http" && (parsed.Hostname() == "localhost" || parsed.Hostname() == "127.0.0.1" || parsed.Hostname() == "::1")
		if !c.AllowInsecureHTTP && !isLocal {
			return errors.New("server_url must use HTTPS unless allow_insecure_http is enabled")
		}
	}
	if c.Interval < time.Second || c.Interval > time.Minute {
		return errors.New("interval must be between 1s and 1m")
	}
	return nil
}

func parseDuration(value string, fallback time.Duration) (time.Duration, error) {
	if strings.TrimSpace(value) == "" {
		return fallback, nil
	}
	return time.ParseDuration(value)
}

func env(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}
