package collector

import (
	"context"
	"encoding/csv"
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
