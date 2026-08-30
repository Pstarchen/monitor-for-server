package model

import "time"

type Report struct {
	CollectedAt       time.Time          `json:"collectedAt"`
	Host              HostInfo           `json:"host"`
	CPU               CPUStats           `json:"cpu"`
	Memory            MemoryStats        `json:"memory"`
	Disks             []DiskStats        `json:"disks"`
	Network           NetworkStats       `json:"network"`
	NetworkInterfaces []NetworkInterface `json:"networkInterfaces"`
	Ports             []PortStats        `json:"ports"`
	Containers        []ContainerStats   `json:"containers"`
	Processes         []ProcessStats     `json:"processes"`
	Services          []ServiceStatus    `json:"services"`
	Firewall          FirewallStatus     `json:"firewall"`
	CronJobs          []CronJob          `json:"cronJobs"`
	Logs              []LogFile          `json:"logs"`
	Integrity         []IntegrityItem    `json:"integrity"`
}

type HostInfo struct {
	Hostname        string        `json:"hostname"`
	OS              string        `json:"os"`
	Platform        string        `json:"platform"`
	PlatformVersion string        `json:"platformVersion"`
	KernelVersion   string        `json:"kernelVersion"`
	Architecture    string        `json:"architecture"`
	UptimeSeconds   uint64        `json:"uptimeSeconds"`
	BootTime        uint64        `json:"bootTime"`
	Temperatures    []Temperature `json:"temperatures"`
	Fans            []Fan         `json:"fans"`
	Batteries       []Battery     `json:"batteries"`
	GPUs            []GPU         `json:"gpus"`
}

type Temperature struct {
	Sensor string  `json:"sensor"`
	Value  float64 `json:"value"`
}

type Fan struct {
	Name string  `json:"name"`
	RPM  float64 `json:"rpm"`
}

type Battery struct {
	Name    string  `json:"name"`
	Percent float64 `json:"percent"`
	Status  string  `json:"status"`
}

type GPU struct {
	Index            int     `json:"index"`
	Name             string  `json:"name"`
	UsagePercent     float64 `json:"usagePercent"`
	MemoryUsedBytes  uint64  `json:"memoryUsedBytes"`
	MemoryTotalBytes uint64  `json:"memoryTotalBytes"`
	Temperature      float64 `json:"temperature"`
}

type CPUStats struct {
	Model          string    `json:"model"`
	LogicalCores   int       `json:"logicalCores"`
	PhysicalCores  int       `json:"physicalCores"`
	UsagePercent   float64   `json:"usagePercent"`
	PerCorePercent []float64 `json:"perCorePercent"`
	Load1          float64   `json:"load1"`
	Load5          float64   `json:"load5"`
	Load15         float64   `json:"load15"`
}

type MemoryStats struct {
	TotalBytes     uint64  `json:"totalBytes"`
	UsedBytes      uint64  `json:"usedBytes"`
	AvailableBytes uint64  `json:"availableBytes"`
	UsagePercent   float64 `json:"usagePercent"`
	CachedBytes    uint64  `json:"cachedBytes"`
	SwapTotalBytes uint64  `json:"swapTotalBytes"`
	SwapUsedBytes  uint64  `json:"swapUsedBytes"`
	SwapPercent    float64 `json:"swapPercent"`
}

type DiskStats struct {
	Device           string       `json:"device"`
	Mountpoint       string       `json:"mountpoint"`
	FileSystem       string       `json:"fileSystem"`
	TotalBytes       uint64       `json:"totalBytes"`
	UsedBytes        uint64       `json:"usedBytes"`
	FreeBytes        uint64       `json:"freeBytes"`
	UsagePercent     float64      `json:"usagePercent"`
	ReadBytesPerSec  float64      `json:"readBytesPerSec"`
	WriteBytesPerSec float64      `json:"writeBytesPerSec"`
	Smart            *SmartHealth `json:"smart,omitempty"`
}

// SmartHealth is intentionally optional: virtual disks, containers and cloud
// volumes commonly do not expose SMART data to the Agent.
type SmartHealth struct {
	Status          string `json:"status"`
	Message         string `json:"message,omitempty"`
	Temperature     int64  `json:"temperature"`
	PowerOnHours    uint64 `json:"powerOnHours"`
	PercentageUsed  int64  `json:"percentageUsed"`
	MediaErrors     uint64 `json:"mediaErrors"`
	UnsafeShutdowns uint64 `json:"unsafeShutdowns"`
}

type NetworkStats struct {
	BytesSentPerSec float64 `json:"bytesSentPerSec"`
	BytesRecvPerSec float64 `json:"bytesRecvPerSec"`
	BytesSent       uint64  `json:"bytesSent"`
	BytesRecv       uint64  `json:"bytesRecv"`
	TCPConnections  int     `json:"tcpConnections"`
}

type NetworkInterface struct {
	Name         string   `json:"name"`
	MTU          int      `json:"mtu"`
	HardwareAddr string   `json:"hardwareAddr"`
	Flags        []string `json:"flags"`
	Addresses    []string `json:"addresses"`
}

type PortStats struct {
	Protocol string `json:"protocol"`
	Address  string `json:"address"`
	Port     uint32 `json:"port"`
	PID      int32  `json:"pid"`
}

type ContainerStats struct {
	ID               string  `json:"id"`
	Name             string  `json:"name"`
	Image            string  `json:"image"`
	State            string  `json:"state"`
	Status           string  `json:"status"`
	CPUPercent       float64 `json:"cpuPercent"`
	MemoryUsageBytes uint64  `json:"memoryUsageBytes"`
	MemoryLimitBytes uint64  `json:"memoryLimitBytes"`
	MemoryPercent    float64 `json:"memoryPercent"`
	NetworkRxBytes   uint64  `json:"networkRxBytes"`
	NetworkTxBytes   uint64  `json:"networkTxBytes"`
	RestartCount     int     `json:"restartCount"`
}

type ProcessStats struct {
	PID           int32   `json:"pid"`
	Name          string  `json:"name"`
	CommandLine   string  `json:"commandLine,omitempty"`
	Username      string  `json:"username"`
	CPUPercent    float64 `json:"cpuPercent"`
	MemoryPercent float32 `json:"memoryPercent"`
	Status        string  `json:"status"`
}

type ServiceStatus struct {
	Name   string `json:"name"`
	Status string `json:"status"`
}

type FirewallStatus struct {
	Provider string `json:"provider"`
	State    string `json:"state"`
	Message  string `json:"message,omitempty"`
}

type CronJob struct {
	Source   string `json:"source"`
	User     string `json:"user,omitempty"`
	Schedule string `json:"schedule"`
	Command  string `json:"command"`
}

type LogFile struct {
	Path       string   `json:"path"`
	SizeBytes  int64    `json:"sizeBytes"`
	ModifiedAt string   `json:"modifiedAt"`
	Lines      []string `json:"lines"`
}

type IntegrityItem struct {
	Path       string `json:"path"`
	SHA256     string `json:"sha256"`
	SizeBytes  int64  `json:"sizeBytes"`
	ModifiedAt string `json:"modifiedAt"`
}
