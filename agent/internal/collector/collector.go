package collector

import (
	"context"
	"fmt"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/shirou/gopsutil/v4/host"
	netstat "github.com/shirou/gopsutil/v4/net"
	"github.com/shirou/gopsutil/v4/sensors"

	"xingchen-monitor/agent/internal/model"
)

type Collector struct {
	options         Options
	mu              sync.Mutex
	cpuPrevious     cpuSample
	processPrevious map[int32]processSample
	diskPrevious    map[string]diskIOSample
	networkPrevious map[string]networkSample
	dockerPrevious  map[string]dockerSample
}

type Options struct {
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
	NetworkInterfaces        []string
	HostRoot                 string
	DockerSocket             string
	LogPaths                 []string
	CollectSystemLogs        bool
	IntegrityPaths           []string
	CustomMetrics            []CustomMetricConfig
}

const maxMonitoredProcesses = 32
const maxProcessCount = 256
const maxPortCount = 512

func New(options Options) *Collector {
	options.MonitoredServices = append([]string(nil), options.MonitoredServices...)
	options.MonitoredProcesses = append([]string(nil), options.MonitoredProcesses...)
	if len(options.MonitoredProcesses) > maxMonitoredProcesses {
		options.MonitoredProcesses = options.MonitoredProcesses[:maxMonitoredProcesses]
	}
	if options.ProcessCollectionLimit <= 0 || options.ProcessCollectionLimit > maxProcessCount {
		options.ProcessCollectionLimit = 12
	}
	if options.PortCollectionLimit <= 0 || options.PortCollectionLimit > maxPortCount {
		options.PortCollectionLimit = maxPortCount
	}
	if options.ContainerCollectionLimit <= 0 || options.ContainerCollectionLimit > maxContainerCount {
		options.ContainerCollectionLimit = maxContainerCount
	}
	options.DiskMountpoints = append([]string(nil), options.DiskMountpoints...)
	options.NetworkInterfaces = append([]string(nil), options.NetworkInterfaces...)
	options.LogPaths = append([]string(nil), options.LogPaths...)
	options.IntegrityPaths = append([]string(nil), options.IntegrityPaths...)
	return &Collector{options: options}
}

func (c *Collector) Collect(ctx context.Context) (model.Report, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := time.Now().UTC()
	hostInfo, err := collectHost(ctx, c.options.HostRoot)
	if err != nil {
		return model.Report{}, err
	}
	cpuInfo, err := c.collectCPU(ctx)
	if err != nil {
		return model.Report{}, err
	}
	memory, err := collectMemory(ctx)
	if err != nil {
		return model.Report{}, err
	}
	disks := c.collectDisks(ctx, c.options.DiskMountpoints, c.options.HostRoot)
	collectDiskHealth(ctx, disks, c.options.HostRoot)
	network := c.collectNetwork(ctx, c.options.SkipConnectionCount)
	interfaces := collectNetworkInterfaces(ctx)
	ports := collectListeningPorts(ctx, c.options.SkipConnectionCount || c.options.SkipPortCollection, c.options.PortCollectionLimit)
	containers := c.collectContainers(ctx, c.options.DockerSocket, c.options.HostRoot, c.options.SkipContainerCollection, c.options.ContainerCollectionLimit)

	processes := make([]model.ProcessStats, 0)
	if !c.options.SkipProcesses {
		limit := c.options.ProcessCollectionLimit
		if !c.options.CollectAllProcesses && limit > 12 {
			limit = 12
		}
		processes = c.collectProcesses(ctx, limit, c.options.MonitoredProcesses)
	}
	return model.Report{
		CollectedAt:       now,
		Host:              hostInfo,
		CPU:               cpuInfo,
		Memory:            memory,
		Disks:             disks,
		Network:           network,
		NetworkInterfaces: interfaces,
		Ports:             ports,
		Containers:        containers,
		Processes:         processes,
		Services:          collectServices(ctx, c.options.MonitoredServices, c.options.HostRoot),
		Firewall:          collectFirewall(ctx, c.options.HostRoot),
		CronJobs:          collectCronJobs(ctx, c.options.HostRoot),
		Logs:              collectLogs(ctx, c.options.LogPaths, c.options.HostRoot),
		SystemLogs:        collectSystemLogs(ctx, c.options.CollectSystemLogs, c.options.HostRoot),
		Integrity:         collectIntegrity(ctx, c.options.IntegrityPaths, c.options.HostRoot),
		CustomMetrics:     collectCustomMetrics(ctx, c.options.CustomMetrics),
	}, nil
}

func collectNetworkInterfaces(ctx context.Context) []model.NetworkInterface {
	items, err := netstat.InterfacesWithContext(ctx)
	if err != nil {
		return []model.NetworkInterface{}
	}
	result := make([]model.NetworkInterface, 0, len(items))
	for _, item := range items {
		addresses := make([]string, 0, len(item.Addrs))
		for _, address := range item.Addrs {
			value := strings.TrimSpace(address.Addr)
			if value != "" {
				addresses = append(addresses, value)
			}
		}
		result = append(result, model.NetworkInterface{
			Name: item.Name, MTU: maxInt(item.MTU, 0), HardwareAddr: item.HardwareAddr,
			Flags: append([]string(nil), item.Flags...), Addresses: addresses,
		})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result
}

func collectListeningPorts(ctx context.Context, skip bool, limit int) []model.PortStats {
	if skip {
		return []model.PortStats{}
	}
	connections, err := netstat.ConnectionsWithContext(ctx, "inet")
	if err != nil {
		return []model.PortStats{}
	}
	return listeningPorts(connections, limit)
}

func listeningPorts(connections []netstat.ConnectionStat, limit int) []model.PortStats {
	result := make([]model.PortStats, 0, len(connections))
	seen := make(map[string]struct{})
	for _, connection := range connections {
		protocol := "TCP"
		if connection.Type == 2 {
			protocol = "UDP"
		}
		if protocol == "TCP" && !strings.EqualFold(connection.Status, "LISTEN") {
			continue
		}
		address := strings.TrimSpace(connection.Laddr.IP)
		if address == "" {
			address = "*"
		}
		key := protocol + ":" + address + ":" + fmt.Sprint(connection.Laddr.Port) + ":" + fmt.Sprint(connection.Pid)
		if _, exists := seen[key]; exists {
			continue
		}
		seen[key] = struct{}{}
		pid := connection.Pid
		if pid < 0 {
			pid = 0
		}
		result = append(result, model.PortStats{Protocol: protocol, Address: address, Port: connection.Laddr.Port, PID: pid})
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].Port == result[j].Port {
			return result[i].Protocol < result[j].Protocol
		}
		return result[i].Port < result[j].Port
	})
	if limit <= 0 || limit > maxPortCount {
		limit = maxPortCount
	}
	if len(result) > limit {
		result = result[:limit]
	}
	return result
}

func maxInt(value, minimum int) int {
	if value < minimum {
		return minimum
	}
	return value
}

func collectHost(ctx context.Context, hostRoot string) (model.HostInfo, error) {
	info, err := host.InfoWithContext(ctx)
	if err != nil {
		return model.HostInfo{}, err
	}
	temperatures, _ := sensors.TemperaturesWithContext(ctx)
	result := model.HostInfo{
		Hostname: info.Hostname, OS: info.OS, Platform: info.Platform,
		PlatformVersion: info.PlatformVersion, KernelVersion: info.KernelVersion,
		Architecture: runtime.GOARCH, UptimeSeconds: info.Uptime, BootTime: info.BootTime,
		Fans: collectFans(hostRoot), Batteries: collectBatteries(hostRoot),
	}
	result.Hostname = reportedHostname(hostRoot, result.Hostname)
	// GPU discovery is intentionally best effort. nvidia-smi is optional and
	// should never prevent CPU/memory metrics from being reported.
	result.GPUs = collectGPUs(ctx)
	for _, sensor := range temperatures {
		if sensor.Temperature > 0 {
			result.Temperatures = append(result.Temperatures, model.Temperature{Sensor: sensor.SensorKey, Value: sensor.Temperature})
		}
	}
	return result, nil
}

// hostPath resolves a host mountpoint inside a read-only host-root bind mount.
// Empty hostRoot retains the normal Agent behavior of reading its own filesystem.
func hostPath(hostRoot, mountpoint string) string {
	hostRoot = strings.TrimSpace(hostRoot)
	if hostRoot == "" {
		return mountpoint
	}
	cleanRoot := filepath.Clean(hostRoot)
	cleanMount := filepath.Clean(mountpoint)
	if !filepath.IsAbs(cleanRoot) || !filepath.IsAbs(cleanMount) {
		return ""
	}
	resolved := filepath.Join(cleanRoot, strings.TrimPrefix(cleanMount, string(filepath.Separator)))
	if resolved != cleanRoot && !strings.HasPrefix(resolved, cleanRoot+string(filepath.Separator)) {
		return ""
	}
	return resolved
}

func allowedMountpoint(mountpoint string, allowlist []string) bool {
	if len(allowlist) == 0 {
		return true
	}
	cleaned := filepath.Clean(mountpoint)
	if runtime.GOOS == "windows" {
		cleaned = diskCounterKey(cleaned)
	}
	for _, allowed := range allowlist {
		candidate := filepath.Clean(allowed)
		if runtime.GOOS == "windows" {
			candidate = diskCounterKey(candidate)
		}
		if cleaned == candidate || (runtime.GOOS == "windows" && strings.EqualFold(cleaned, candidate)) {
			return true
		}
	}
	return false
}

func trimCommandLine(value string) string {
	value = strings.TrimSpace(value)
	runes := []rune(value)
	if len(runes) > 2048 {
		return string(runes[:2048])
	}
	return value
}

func matchesMonitoredProcess(name string, monitored []string) bool {
	name = strings.TrimSpace(name)
	if name == "" {
		return false
	}
	for _, candidate := range monitored {
		candidate = strings.TrimSpace(candidate)
		if candidate == "" {
			continue
		}
		if strings.EqualFold(name, candidate) {
			return true
		}
		if runtime.GOOS == "windows" && strings.EqualFold(strings.TrimSuffix(name, ".exe"), strings.TrimSuffix(candidate, ".exe")) {
			return true
		}
	}
	return false
}

func rate(current, previous uint64, seconds float64) float64 {
	if current < previous || seconds <= 0 {
		return 0
	}
	return float64(current-previous) / seconds
}
