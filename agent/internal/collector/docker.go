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
	"sync"
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
	CPUStats    dockerCPUStats            `json:"cpu_stats"`
	PreCPUStats dockerCPUStats            `json:"precpu_stats"`
	MemoryStats dockerMemoryStats         `json:"memory_stats"`
	Networks    map[string]dockerNetStats `json:"networks"`
	Read        time.Time                 `json:"read"`
}

type dockerCPUStats struct {
	CPUUsage struct {
		TotalUsage  uint64   `json:"total_usage"`
		PerCPUUsage []uint64 `json:"percpu_usage"`
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

type dockerSample struct {
	cpu       dockerCPUStats
	read      time.Time
	startedAt string
}

type dockerInspect struct {
	RestartCount *int `json:"RestartCount"`
	State        struct {
		StartedAt string `json:"StartedAt"`
	} `json:"State"`
}

func (c *Collector) collectContainers(ctx context.Context, configuredSocket, hostRoot string, skip bool, limit int) []model.ContainerStats {
	if skip {
		c.dockerPrevious = nil
		return []model.ContainerStats{}
	}
	socket := resolveDockerSocket(configuredSocket, hostRoot)
	if socket == "" {
		c.dockerPrevious = nil
		return []model.ContainerStats{}
	}
	client := dockerClient(socket)
	defer client.CloseIdleConnections()
	return c.collectDockerContainers(ctx, client, limit)
}

func (c *Collector) collectDockerContainers(ctx context.Context, client *http.Client, limit int) []model.ContainerStats {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	var summaries []dockerContainerSummary
	if err := dockerGet(ctx, client, "/v1.41/containers/json?all=1", &summaries); err != nil {
		c.dockerPrevious = nil
		return []model.ContainerStats{}
	}
	sort.Slice(summaries, func(i, j int) bool { return dockerContainerName(summaries[i]) < dockerContainerName(summaries[j]) })
	if limit <= 0 || limit > maxContainerCount {
		limit = maxContainerCount
	}
	if len(summaries) > limit {
		summaries = summaries[:limit]
	}
	result := make([]model.ContainerStats, len(summaries))
	samples := make([]*dockerSample, len(summaries))
	jobs := make(chan int)
	var workers sync.WaitGroup
	// One-shot stats avoid Docker's one-second double sample for each container.
	// Four workers bound daemon load while avoiding serial head-of-line delays.
	for worker := 0; worker < 4; worker++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for index := range jobs {
				summary := summaries[index]
				item := model.ContainerStats{ID: strings.TrimSpace(summary.ID), Name: dockerContainerName(summary), Image: strings.TrimSpace(summary.Image), State: strings.TrimSpace(summary.State), Status: strings.TrimSpace(summary.Status)}
				if item.ID != "" {
					var stats dockerContainerStats
					statsOK := false
					if strings.EqualFold(item.State, "running") {
						statsOK = dockerGet(ctx, client, "/v1.41/containers/"+url.PathEscape(item.ID)+"/stats?stream=false&one-shot=true", &stats) == nil && !stats.Read.IsZero()
					}
					// Inspect after reading counters. A restart between these calls
					// then has StartedAt later than stats.Read, so old counters cannot
					// become the baseline for the new container instance.
					var inspected dockerInspect
					inspectErr := dockerGet(ctx, client, "/v1.41/containers/"+url.PathEscape(item.ID)+"/json", &inspected)
					if inspectErr == nil && inspected.RestartCount != nil && *inspected.RestartCount >= 0 {
						item.RestartCount = *inspected.RestartCount
						item.RestartCountAvailable = true
					}
					startedAt, startedErr := time.Parse(time.RFC3339Nano, inspected.State.StartedAt)
					if inspectErr == nil && startedErr == nil && !startedAt.IsZero() && stats.Read.Before(startedAt) {
						statsOK = false
					}
					if statsOK {
						item.StatsAvailable = true
						item.MemoryUsageBytes, item.MemoryLimitBytes, item.MemoryPercent = dockerMemoryPercent(stats)
						item.NetworkRxBytes, item.NetworkTxBytes = dockerNetworkTotals(stats.Networks)
						// Missing instance metadata, duplicate daemon samples, counter
						// resets and CPU hotplug must not invent a valid CPU interval.
						if inspectErr == nil && startedErr == nil && !startedAt.IsZero() {
							previous, exists := c.dockerPrevious[item.ID]
							current := dockerSample{cpu: stats.CPUStats, read: stats.Read, startedAt: inspected.State.StartedAt}
							samples[index] = &current
							if exists && previous.startedAt == current.startedAt && current.read.After(previous.read) &&
								current.cpu.SystemCPUUsage > previous.cpu.SystemCPUUsage && current.cpu.CPUUsage.TotalUsage >= previous.cpu.CPUUsage.TotalUsage &&
								dockerOnlineCPUs(current.cpu) > 0 && dockerOnlineCPUs(current.cpu) == dockerOnlineCPUs(previous.cpu) {
								stats.PreCPUStats = previous.cpu
								item.CPUPercent = dockerCPUPercent(stats)
								item.CPUSampled = true
							}
						}
					}
				}
				result[index] = item
			}
		}()
	}
	for index := range summaries {
		jobs <- index
	}
	close(jobs)
	workers.Wait()
	next := make(map[string]dockerSample)
	filtered := make([]model.ContainerStats, 0, len(result))
	for index, item := range result {
		if item.ID == "" {
			continue
		}
		filtered = append(filtered, item)
		if samples[index] != nil {
			next[item.ID] = *samples[index]
		}
	}
	c.dockerPrevious = next
	return filtered
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
	online := dockerOnlineCPUs(stats.CPUStats)
	value := float64(cpuDelta) / float64(systemDelta) * float64(online) * 100
	if !math.IsNaN(value) && !math.IsInf(value, 0) && value > 0 {
		return value
	}
	return 0
}

func dockerMemoryPercent(stats dockerContainerStats) (uint64, uint64, float64) {
	usage := stats.MemoryStats.Usage
	// Match Docker CLI: cgroup v1 total_inactive_file, then v2 inactive_file.
	// The general cache counter also contains active memory and is not equivalent.
	if inactive, exists := stats.MemoryStats.Stats["total_inactive_file"]; exists && inactive < usage {
		usage -= inactive
	} else if inactive := stats.MemoryStats.Stats["inactive_file"]; inactive < usage {
		usage -= inactive
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

func dockerOnlineCPUs(stats dockerCPUStats) uint32 {
	if stats.OnlineCPUs > 0 {
		return stats.OnlineCPUs
	}
	return uint32(len(stats.CPUUsage.PerCPUUsage))
}
