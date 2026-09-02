package collector

import (
	"context"
	"encoding/json"
	"io"
	"math"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"time"

	"xingchen-monitor/agent/internal/model"
)

const maxContainerCount = 100

type dockerContainerSummary struct {
	ID     string   `json:"Id"`
	Names  []string `json:"Names"`
	Image  string   `json:"Image"`
	State  string   `json:"State"`
	Status string   `json:"Status"`
}

type dockerContainerStats struct {
	CPUStats     dockerCPUStats            `json:"cpu_stats"`
	PreCPUStats  dockerCPUStats            `json:"precpu_stats"`
	MemoryStats  dockerMemoryStats         `json:"memory_stats"`
	Networks     map[string]dockerNetStats `json:"networks"`
	RestartCount int                       `json:"restart_count"`
}

type dockerCPUStats struct {
	CPUUsage struct {
		TotalUsage uint64 `json:"total_usage"`
	} `json:"cpu_usage"`
	SystemCPUUsage uint64 `json:"system_cpu_usage"`
	OnlineCPUs     uint32 `json:"online_cpus"`
}

type dockerMemoryStats struct {
	Usage uint64            `json:"usage"`
	Limit uint64            `json:"limit"`
	Stats map[string]uint64 `json:"stats"`
}

type dockerNetStats struct {
	RxBytes uint64 `json:"rx_bytes"`
	TxBytes uint64 `json:"tx_bytes"`
}

func collectContainers(ctx context.Context, configuredSocket, hostRoot string, skip bool, limit int) []model.ContainerStats {
	if skip {
		return []model.ContainerStats{}
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	socket := resolveDockerSocket(configuredSocket, hostRoot)
	if socket == "" {
		return []model.ContainerStats{}
	}
	client := dockerClient(socket)
	defer client.CloseIdleConnections()

	var summaries []dockerContainerSummary
	if err := dockerGet(ctx, client, "/v1.41/containers/json?all=1", &summaries); err != nil {
		return []model.ContainerStats{}
	}
	sort.Slice(summaries, func(i, j int) bool {
		return dockerContainerName(summaries[i]) < dockerContainerName(summaries[j])
	})
	if limit <= 0 || limit > maxContainerCount {
		limit = maxContainerCount
	}
	if len(summaries) > limit {
		summaries = summaries[:limit]
	}

	result := make([]model.ContainerStats, 0, len(summaries))
	for _, summary := range summaries {
		item := model.ContainerStats{
			ID:     strings.TrimSpace(summary.ID),
			Name:   dockerContainerName(summary),
			Image:  strings.TrimSpace(summary.Image),
			State:  strings.TrimSpace(summary.State),
			Status: strings.TrimSpace(summary.Status),
		}
		if item.ID == "" {
			continue
		}
		if strings.EqualFold(item.State, "running") {
			var stats dockerContainerStats
			if err := dockerGet(ctx, client, "/v1.41/containers/"+url.PathEscape(item.ID)+"/stats?stream=false", &stats); err == nil {
				item.CPUPercent = dockerCPUPercent(stats)
				item.MemoryUsageBytes, item.MemoryLimitBytes, item.MemoryPercent = dockerMemoryPercent(stats)
				item.NetworkRxBytes, item.NetworkTxBytes = dockerNetworkTotals(stats.Networks)
				item.RestartCount = maxInt(stats.RestartCount, 0)
			}
		}
		result = append(result, item)
	}
	return result
}

func resolveDockerSocket(configured, hostRoot string) string {
	if value := strings.TrimSpace(configured); value != "" {
		if isDockerSocket(value) {
			return value
		}
	}
	candidates := []string{"/var/run/docker.sock", "/run/podman/podman.sock"}
	for _, socket := range []string{"/var/run/docker.sock", "/run/podman/podman.sock"} {
		if value := hostPath(hostRoot, socket); value != "" && !containsString(candidates, value) {
			candidates = append(candidates, value)
		}
	}
	for _, candidate := range candidates {
		if isDockerSocket(candidate) {
			return candidate
		}
	}
	return ""
}

func isDockerSocket(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode()&os.ModeSocket != 0
}

func containsString(values []string, candidate string) bool {
	for _, value := range values {
		if value == candidate {
			return true
		}
	}
	return false
}

func dockerClient(socket string) *http.Client {
	transport := &http.Transport{
		DisableKeepAlives: true,
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", socket)
		},
	}
	return &http.Client{Transport: transport}
}

func dockerGet(ctx context.Context, client *http.Client, path string, target any) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://docker"+path, nil)
	if err != nil {
		return err
	}
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return io.ErrUnexpectedEOF
	}
	decoder := json.NewDecoder(io.LimitReader(response.Body, 2<<20))
	return decoder.Decode(target)
}

func dockerContainerName(summary dockerContainerSummary) string {
	for _, name := range summary.Names {
		if value := strings.Trim(strings.TrimSpace(name), "/"); value != "" {
			return value
		}
	}
	value := strings.TrimSpace(summary.ID)
	if len(value) > 12 {
		return value[:12]
	}
	return value
}

func dockerCPUPercent(stats dockerContainerStats) float64 {
	if stats.CPUStats.SystemCPUUsage <= stats.PreCPUStats.SystemCPUUsage || stats.CPUStats.CPUUsage.TotalUsage <= stats.PreCPUStats.CPUUsage.TotalUsage {
		return 0
	}
	cpuDelta := stats.CPUStats.CPUUsage.TotalUsage - stats.PreCPUStats.CPUUsage.TotalUsage
	systemDelta := stats.CPUStats.SystemCPUUsage - stats.PreCPUStats.SystemCPUUsage
	online := stats.CPUStats.OnlineCPUs
	if online == 0 {
		online = 1
	}
	value := float64(cpuDelta) / float64(systemDelta) * float64(online) * 100
	if !math.IsNaN(value) && !math.IsInf(value, 0) && value > 0 {
		return value
	}
	return 0
}

func dockerMemoryPercent(stats dockerContainerStats) (uint64, uint64, float64) {
	usage := stats.MemoryStats.Usage
	cache := stats.MemoryStats.Stats["cache"]
	if cache == 0 {
		cache = stats.MemoryStats.Stats["inactive_file"]
	}
	if cache > 0 && usage > cache {
		usage -= cache
	}
	limit := stats.MemoryStats.Limit
	if limit == 0 {
		return usage, 0, 0
	}
	value := float64(usage) / float64(limit) * 100
	if math.IsNaN(value) || math.IsInf(value, 0) || value < 0 {
		value = 0
	}
	return usage, limit, value
}

func dockerNetworkTotals(networks map[string]dockerNetStats) (uint64, uint64) {
	var received, sent uint64
	for _, network := range networks {
		received += network.RxBytes
		sent += network.TxBytes
	}
	return received, sent
}
