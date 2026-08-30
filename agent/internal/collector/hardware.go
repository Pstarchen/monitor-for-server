package collector

import (
	"context"
	"encoding/csv"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"guanlan-monitor/agent/internal/model"
)

type smartctlPayload struct {
	SmartStatus *struct {
		Passed *bool `json:"passed"`
	} `json:"smart_status"`
	Temperature *struct {
		Current float64 `json:"current"`
	} `json:"temperature"`
	PowerOnTime *struct {
		Hours uint64 `json:"hours"`
	} `json:"power_on_time"`
	NVMeLog *struct {
		CriticalWarning uint64  `json:"critical_warning"`
		Temperature     float64 `json:"temperature"`
		PercentageUsed  uint64  `json:"percentage_used"`
		PowerOnHours    uint64  `json:"power_on_hours"`
		MediaErrors     uint64  `json:"media_errors"`
		UnsafeShutdowns uint64  `json:"unsafe_shutdowns"`
	} `json:"nvme_smart_health_information_log"`
	ATAAttributes *struct {
		Table []struct {
			Name string `json:"name"`
			Raw  struct {
				Value uint64 `json:"value"`
			} `json:"raw"`
		} `json:"table"`
	} `json:"ata_smart_attributes"`
}

// collectFans reads the standard Linux hwmon interface. Missing sensors are
// expected on VMs and most cloud hosts, so this function always degrades to an
// empty list instead of failing the host report.
func collectFans(hostRoot string) []model.Fan {
	if runtime.GOOS != "linux" {
		return []model.Fan{}
	}
	root := hostPath(hostRoot, "/sys/class/hwmon")
	if root == "" {
		return []model.Fan{}
	}
	paths, _ := filepath.Glob(filepath.Join(root, "hwmon*", "fan*_input"))
	result := make([]model.Fan, 0, len(paths))
	for _, path := range paths {
		value, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		rpm, err := strconv.ParseFloat(strings.TrimSpace(string(value)), 64)
		if err != nil || rpm < 0 {
			continue
		}
		name := strings.TrimSpace(filepath.Base(filepath.Dir(path))) + "/" + strings.TrimSuffix(filepath.Base(path), "_input")
		if label, err := os.ReadFile(filepath.Join(filepath.Dir(path), "name")); err == nil && strings.TrimSpace(string(label)) != "" {
			name = strings.TrimSpace(string(label)) + "/" + strings.TrimSuffix(filepath.Base(path), "_input")
		}
		result = append(result, model.Fan{Name: name, RPM: rpm})
	}
	return result
}

func collectBatteries(hostRoot string) []model.Battery {
	if runtime.GOOS != "linux" {
		return []model.Battery{}
	}
	root := hostPath(hostRoot, "/sys/class/power_supply")
	if root == "" {
		return []model.Battery{}
	}
	directories, _ := filepath.Glob(filepath.Join(root, "*"))
	result := make([]model.Battery, 0, len(directories))
	for _, directory := range directories {
		kind, err := os.ReadFile(filepath.Join(directory, "type"))
		if err != nil || !strings.EqualFold(strings.TrimSpace(string(kind)), "battery") {
			continue
		}
		capacity, err := os.ReadFile(filepath.Join(directory, "capacity"))
		if err != nil {
			continue
		}
		percent, err := strconv.ParseFloat(strings.TrimSpace(string(capacity)), 64)
		if err != nil || percent < 0 || percent > 100 {
			continue
		}
		status := ""
		if value, readErr := os.ReadFile(filepath.Join(directory, "status")); readErr == nil {
			status = strings.TrimSpace(string(value))
		}
		result = append(result, model.Battery{Name: filepath.Base(directory), Percent: percent, Status: status})
	}
	return result
}

func collectGPUs(ctx context.Context) []model.GPU {
	if _, err := exec.LookPath("nvidia-smi"); err != nil {
		return []model.GPU{}
	}
	gpuCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	command := exec.CommandContext(gpuCtx, "nvidia-smi", "--query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu", "--format=csv,noheader,nounits")
	output, err := command.Output()
	if err != nil {
		return []model.GPU{}
	}
	reader := csv.NewReader(strings.NewReader(string(output)))
	reader.TrimLeadingSpace = true
	result := make([]model.GPU, 0)
	for {
		row, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil || len(row) < 6 {
			continue
		}
		index, err := strconv.Atoi(strings.TrimSpace(row[0]))
		if err != nil {
			continue
		}
		gpu := model.GPU{Index: index, Name: strings.TrimSpace(row[1])}
		gpu.UsagePercent = parseHardwareFloat(row[2], 0, 100)
		gpu.MemoryUsedBytes = parseMiB(row[3])
		gpu.MemoryTotalBytes = parseMiB(row[4])
		gpu.Temperature = parseHardwareFloat(row[5], -273.15, 1000)
		result = append(result, gpu)
	}
	return result
}

// collectDiskHealth uses smartctl when the host exposes it. SMART is a
// best-effort signal: cloud volumes, virtual disks and unprivileged agents
// legitimately return UNKNOWN and must not make the report fail.
func collectDiskHealth(ctx context.Context, disks []model.DiskStats, hostRoot string) {
	if runtime.GOOS != "linux" {
		return
	}
	if _, err := exec.LookPath("smartctl"); err != nil {
		return
	}
	results := make(map[string]*model.SmartHealth)
	for index := range disks {
		device := smartDevicePath(disks[index].Device, hostRoot)
		if device == "" {
			continue
		}
		if health, ok := results[device]; ok {
			disks[index].Smart = health
			continue
		}
		commandCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		output, err := exec.CommandContext(commandCtx, "smartctl", "-j", "-H", "-A", device).Output()
		cancel()
		health := parseSmartctlReport(output, err)
		results[device] = health
		disks[index].Smart = health
	}
}

func smartDevicePath(device, hostRoot string) string {
	device = strings.TrimSpace(device)
	if !strings.HasPrefix(device, "/dev/") {
		return ""
	}
	if hostRoot == "" {
		return device
	}
	return hostPath(hostRoot, device)
}

func parseSmartctlReport(output []byte, commandErr error) *model.SmartHealth {
	health := &model.SmartHealth{Status: "UNKNOWN", Message: "SMART 数据不可用"}
	var payload smartctlPayload
	if len(output) == 0 || json.Unmarshal(output, &payload) != nil {
		if commandErr != nil {
			health.Message = "smartctl 无法访问设备"
		}
		return health
	}
	if payload.Temperature != nil && payload.Temperature.Current >= -273 && payload.Temperature.Current <= 1000 {
		health.Temperature = int64(payload.Temperature.Current)
	}
	if payload.PowerOnTime != nil {
		health.PowerOnHours = payload.PowerOnTime.Hours
	}
	if payload.NVMeLog != nil {
		health.Temperature = int64(payload.NVMeLog.Temperature)
		health.PercentageUsed = minInt64(int64(payload.NVMeLog.PercentageUsed), 100)
		health.PowerOnHours = payload.NVMeLog.PowerOnHours
		health.MediaErrors = payload.NVMeLog.MediaErrors
		health.UnsafeShutdowns = payload.NVMeLog.UnsafeShutdowns
		if payload.NVMeLog.CriticalWarning > 0 {
			health.Status = "FAILED"
			health.Message = "NVMe 报告关键警告"
			return health
		}
	}
	if payload.ATAAttributes != nil {
		for _, attribute := range payload.ATAAttributes.Table {
			switch strings.ToLower(strings.TrimSpace(attribute.Name)) {
			case "percentage used", "percent lifetime used":
				health.PercentageUsed = minInt64(int64(attribute.Raw.Value), 100)
			case "media and data integrity errors", "reported uncorrectable errors":
				health.MediaErrors = attribute.Raw.Value
			}
		}
	}
	if payload.SmartStatus != nil && payload.SmartStatus.Passed != nil {
		if *payload.SmartStatus.Passed {
			health.Status = "PASSED"
			health.Message = "SMART 自检通过"
		} else {
			health.Status = "FAILED"
			health.Message = "SMART 自检未通过"
		}
	}
	if health.Status == "UNKNOWN" && commandErr == nil {
		health.Message = "设备未提供可判定的 SMART 状态"
	}
	return health
}

func minInt64(value, maximum int64) int64 {
	if value < 0 {
		return 0
	}
	if value > maximum {
		return maximum
	}
	return value
}

func parseHardwareFloat(value string, minimum, maximum float64) float64 {
	parsed, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
	if err != nil || parsed < minimum || parsed > maximum {
		return 0
	}
	return parsed
}

func parseMiB(value string) uint64 {
	parsed, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
	if err != nil || parsed < 0 {
		return 0
	}
	return uint64(parsed * 1024 * 1024)
}
