package model

import "time"

type Report struct {
	CollectedAt time.Time       `json:"collectedAt"`
	Host        HostInfo        `json:"host"`
	CPU         CPUStats        `json:"cpu"`
	Memory      MemoryStats     `json:"memory"`
	Disks       []DiskStats     `json:"disks"`
	Network     NetworkStats    `json:"network"`
	Processes   []ProcessStats  `json:"processes"`
	Services    []ServiceStatus `json:"services"`
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
}

type Temperature struct {
	Sensor string  `json:"sensor"`
	Value  float64 `json:"value"`
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
	Device           string  `json:"device"`
	Mountpoint       string  `json:"mountpoint"`
	FileSystem       string  `json:"fileSystem"`
	TotalBytes       uint64  `json:"totalBytes"`
	UsedBytes        uint64  `json:"usedBytes"`
	FreeBytes        uint64  `json:"freeBytes"`
	UsagePercent     float64 `json:"usagePercent"`
	ReadBytesPerSec  float64 `json:"readBytesPerSec"`
	WriteBytesPerSec float64 `json:"writeBytesPerSec"`
}

type NetworkStats struct {
	BytesSentPerSec float64 `json:"bytesSentPerSec"`
	BytesRecvPerSec float64 `json:"bytesRecvPerSec"`
	TCPConnections  int     `json:"tcpConnections"`
}

type ProcessStats struct {
	PID           int32   `json:"pid"`
	Name          string  `json:"name"`
	Username      string  `json:"username"`
	CPUPercent    float64 `json:"cpuPercent"`
	MemoryPercent float32 `json:"memoryPercent"`
	Status        string  `json:"status"`
}

type ServiceStatus struct {
	Name   string `json:"name"`
	Status string `json:"status"`
}
