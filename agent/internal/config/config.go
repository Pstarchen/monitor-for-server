package config

import (
	"bytes"
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
	ServerURL                string
	DeviceID                 string
	AgentKey                 string
	Interval                 time.Duration
	RequestTimeout           time.Duration
	SpoolDir                 string
	MaxBufferedReports       int
	AllowInsecureHTTP        bool
	MonitoredServices        []string
	MonitoredProcesses       []string
	SkipProcesses            bool
	CollectAllProcesses      bool
	ProcessCollectionLimit   int
	SkipConnectionCount      bool
	SkipPortCollection       bool
	PortCollectionLimit      int
	SkipContainerCollection  bool
	ContainerCollectionLimit int
	DiskMountpoints          []string
	HostRoot                 string
	DockerSocket             string
	LogPaths                 []string
	CollectSystemLogs        bool
	IntegrityPaths           []string
	CustomMetrics            []CustomMetric
	AllowCommandExecution    bool
	AllowFileOperations      bool
	CommandPollInterval      time.Duration
	MaxCommandOutputBytes    int
}

type fileConfig struct {
	ServerURL                string         `json:"server_url"`
	DeviceID                 string         `json:"device_id"`
	AgentKey                 string         `json:"agent_key"`
	Interval                 string         `json:"interval"`
	RequestTimeout           string         `json:"request_timeout"`
	SpoolDir                 string         `json:"spool_dir"`
	MaxBufferedReports       int            `json:"max_buffered_reports"`
	AllowInsecureHTTP        bool           `json:"allow_insecure_http"`
	MonitoredServices        []string       `json:"monitored_services"`
	MonitoredProcesses       []string       `json:"monitored_processes"`
	SkipProcesses            bool           `json:"skip_process_collection"`
	CollectAllProcesses      bool           `json:"collect_all_processes"`
	ProcessCollectionLimit   int            `json:"process_collection_limit"`
	SkipConnectionCount      bool           `json:"skip_connection_count"`
	SkipPortCollection       bool           `json:"skip_port_collection"`
	PortCollectionLimit      int            `json:"port_collection_limit"`
	SkipContainerCollection  bool           `json:"skip_container_collection"`
	ContainerCollectionLimit int            `json:"container_collection_limit"`
	DiskMountpoints          []string       `json:"disk_mountpoints"`
	HostRoot                 string         `json:"host_root"`
	DockerSocket             string         `json:"docker_socket"`
	LogPaths                 []string       `json:"log_paths"`
	CollectSystemLogs        bool           `json:"collect_system_logs"`
	IntegrityPaths           []string       `json:"integrity_paths"`
	CustomMetrics            []CustomMetric `json:"custom_metrics"`
	AllowCommandExecution    bool           `json:"allow_command_execution"`
	AllowFileOperations      bool           `json:"allow_file_operations"`
	CommandPollInterval      string         `json:"command_poll_interval"`
	MaxCommandOutputBytes    int            `json:"max_command_output_bytes"`
}

type CustomMetric struct {
	Name    string   `json:"name"`
	Command string   `json:"command"`
	Args    []string `json:"args"`
	Kind    string   `json:"kind"`
}

func Load(args []string) (Config, error) {
	flags := flag.NewFlagSet("xingchen-agent", flag.ContinueOnError)
	configPath := flags.String("config", envCompat("XINGCHEN_AGENT_CONFIG", "GUANLAN_AGENT_CONFIG", "agent.json"), "path to JSON configuration")
	if err := flags.Parse(args); err != nil {
		return Config{}, err
	}

	raw, err := os.ReadFile(filepath.Clean(*configPath))
	if err != nil {
		return Config{}, fmt.Errorf("read config: %w", err)
	}
	var file fileConfig
	raw = bytes.TrimPrefix(raw, []byte{0xEF, 0xBB, 0xBF})
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
	pollInterval, err := parseDuration(file.CommandPollInterval, time.Second)
	if err != nil {
		return Config{}, fmt.Errorf("command_poll_interval: %w", err)
	}
	maxCommandOutput := file.MaxCommandOutputBytes
	if maxCommandOutput <= 0 {
		maxCommandOutput = 65536
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
		MonitoredProcesses:  cleanList(file.MonitoredProcesses),
		SkipProcesses:       file.SkipProcesses,
		CollectAllProcesses: file.CollectAllProcesses,
		ProcessCollectionLimit: positiveOrDefault(file.ProcessCollectionLimit, func() int {
			if file.CollectAllProcesses {
				return 256
			}
			return 12
		}()),
		SkipConnectionCount:      file.SkipConnectionCount,
		SkipPortCollection:       file.SkipPortCollection,
		PortCollectionLimit:      positiveOrDefault(file.PortCollectionLimit, 512),
		SkipContainerCollection:  file.SkipContainerCollection,
		ContainerCollectionLimit: positiveOrDefault(file.ContainerCollectionLimit, 100),
		DiskMountpoints:          cleanList(file.DiskMountpoints),
		HostRoot:                 strings.TrimSpace(file.HostRoot),
		DockerSocket:             strings.TrimSpace(file.DockerSocket),
		LogPaths:                 cleanList(file.LogPaths),
		CollectSystemLogs:        file.CollectSystemLogs,
		IntegrityPaths:           cleanList(file.IntegrityPaths),
		CustomMetrics:            cleanCustomMetrics(file.CustomMetrics),
		AllowCommandExecution:    file.AllowCommandExecution,
		AllowFileOperations:      file.AllowFileOperations,
		CommandPollInterval:      pollInterval,
		MaxCommandOutputBytes:    maxCommandOutput,
	}
	return cfg, cfg.Validate()
}

func cleanCustomMetrics(values []CustomMetric) []CustomMetric {
	if len(values) > 32 {
		values = values[:32]
	}
	result := make([]CustomMetric, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		value.Name = strings.TrimSpace(value.Name)
		value.Command = strings.TrimSpace(value.Command)
		value.Kind = strings.ToLower(strings.TrimSpace(value.Kind))
		if value.Kind == "" {
			value.Kind = "number"
		}
		value.Args = cleanList(value.Args)
		if value.Name == "" || value.Command == "" || len(value.Name) > 80 || len(value.Command) > 128 || len(value.Args) > 16 || (value.Kind != "number" && value.Kind != "text" && value.Kind != "exit_code") {
			continue
		}
		validArgs := true
		for _, arg := range value.Args {
			if len(arg) > 256 || strings.ContainsRune(arg, '\x00') {
				validArgs = false
				break
			}
		}
		if !validArgs {
			continue
		}
		if _, exists := seen[value.Name]; exists {
			continue
		}
		seen[value.Name] = struct{}{}
		result = append(result, value)
	}
	return result
}

func positiveOrDefault(value, fallback int) int {
	if value <= 0 {
		return fallback
	}
	return value
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
	if parsed.User != nil || (parsed.Path != "" && parsed.Path != "/") || parsed.RawQuery != "" || parsed.Fragment != "" {
		return errors.New("server_url must be an origin without credentials, path, query or fragment")
	}
	if parsed.Scheme != "https" && parsed.Scheme != "http" {
		return errors.New("server_url must use HTTP or HTTPS")
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
	if c.CommandPollInterval < 500*time.Millisecond || c.CommandPollInterval > time.Minute {
		return errors.New("command_poll_interval must be between 500ms and 1m")
	}
	if c.MaxCommandOutputBytes < 1024 || c.MaxCommandOutputBytes > 1<<20 {
		return errors.New("max_command_output_bytes must be between 1024 and 1048576")
	}
	if c.RequestTimeout < time.Second || c.RequestTimeout > 2*time.Minute {
		return errors.New("request_timeout must be between 1s and 2m")
	}
	if c.MaxBufferedReports < 1 || c.MaxBufferedReports > 100000 {
		return errors.New("max_buffered_reports must be between 1 and 100000")
	}
	if c.ProcessCollectionLimit < 1 || c.ProcessCollectionLimit > 256 {
		return errors.New("process_collection_limit must be between 1 and 256")
	}
	if c.PortCollectionLimit < 1 || c.PortCollectionLimit > 512 {
		return errors.New("port_collection_limit must be between 1 and 512")
	}
	if c.ContainerCollectionLimit < 1 || c.ContainerCollectionLimit > 100 {
		return errors.New("container_collection_limit must be between 1 and 100")
	}
	if len(c.CustomMetrics) > 32 {
		return errors.New("custom_metrics must contain at most 32 items")
	}
	for _, metric := range c.CustomMetrics {
		if metric.Name == "" || metric.Command == "" || len(metric.Name) > 80 || len(metric.Command) > 128 || len(metric.Args) > 16 {
			return errors.New("custom metric definition is invalid")
		}
		if metric.Kind != "number" && metric.Kind != "text" && metric.Kind != "exit_code" {
			return errors.New("custom metric kind must be number, text or exit_code")
		}
		for _, arg := range metric.Args {
			if len(arg) > 256 || strings.ContainsRune(arg, '\x00') {
				return errors.New("custom metric argument is invalid")
			}
		}
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

func envCompat(primary, legacy, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(primary)); value != "" {
		return value
	}
	if value := strings.TrimSpace(os.Getenv(legacy)); value != "" {
		return value
	}
	return fallback
}
