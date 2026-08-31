package collector

import (
	"context"
	"crypto/sha256"
	"encoding/csv"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	"guanlan-monitor/agent/internal/model"
)

var cronSecretPattern = regexp.MustCompile(`(?i)(password|passwd|token|secret|api[_-]?key)=\S+`)
var cronSecretArgPattern = regexp.MustCompile(`(?i)(--?(?:password|passwd|token|secret|api[_-]?key)|-p)(?:=|\s+)\S+`)

func collectFirewall(parent context.Context, hostRoot string) model.FirewallStatus {
	if runtime.GOOS == "windows" {
		output, err := runHostCommand(parent, hostRoot, "netsh", "advfirewall", "show", "allprofiles", "state")
		if err != nil {
			return model.FirewallStatus{Provider: "windows-firewall", State: "UNKNOWN", Message: "无法读取 Windows 防火墙状态"}
		}
		if strings.Contains(strings.ToLower(output), "on") {
			return model.FirewallStatus{Provider: "windows-firewall", State: "ACTIVE", Message: "Windows 防火墙已启用"}
		}
		if strings.Contains(strings.ToLower(output), "off") {
			return model.FirewallStatus{Provider: "windows-firewall", State: "INACTIVE", Message: "Windows 防火墙未启用"}
		}
		return model.FirewallStatus{Provider: "windows-firewall", State: "UNKNOWN", Message: "Windows 防火墙状态未知"}
	}
	if runtime.GOOS != "linux" {
		return model.FirewallStatus{Provider: "unsupported", State: "UNKNOWN", Message: "当前系统不支持防火墙巡检"}
	}
	checks := []struct {
		provider string
		command  string
		args     []string
	}{
		{provider: "ufw", command: "ufw", args: []string{"status"}},
		{provider: "firewalld", command: "firewall-cmd", args: []string{"--state"}},
		{provider: "nftables", command: "nft", args: []string{"list", "ruleset"}},
		{provider: "iptables", command: "iptables", args: []string{"-S"}},
	}
	for _, check := range checks {
		output, err := runHostCommand(parent, hostRoot, check.command, check.args...)
		if err != nil {
			continue
		}
		text := strings.ToLower(strings.TrimSpace(output))
		switch check.provider {
		case "ufw":
			if strings.Contains(text, "status: active") {
				return model.FirewallStatus{Provider: check.provider, State: "ACTIVE", Message: "UFW 已启用"}
			}
			if strings.Contains(text, "status: inactive") {
				return model.FirewallStatus{Provider: check.provider, State: "INACTIVE", Message: "UFW 未启用"}
			}
		case "firewalld":
			if strings.Contains(text, "running") {
				return model.FirewallStatus{Provider: check.provider, State: "ACTIVE", Message: "firewalld 正在运行"}
			}
			if strings.Contains(text, "not running") {
				return model.FirewallStatus{Provider: check.provider, State: "INACTIVE", Message: "firewalld 未运行"}
			}
		default:
			if text != "" {
				return model.FirewallStatus{Provider: check.provider, State: "ACTIVE", Message: check.provider + " 规则可读取"}
			}
		}
	}
	return model.FirewallStatus{Provider: "unknown", State: "UNKNOWN", Message: "未检测到可读取的防火墙服务"}
}

func runHostCommand(parent context.Context, hostRoot, command string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(parent, 3*time.Second)
	defer cancel()
	if runtime.GOOS == "linux" && strings.TrimSpace(hostRoot) != "" {
		root := filepath.Clean(hostRoot)
		if !filepath.IsAbs(root) {
			return "", errors.New("invalid host root")
		}
		commandArgs := append([]string{root, command}, args...)
		return stringOutput(exec.CommandContext(ctx, "chroot", commandArgs...))
	}
	return stringOutput(exec.CommandContext(ctx, command, args...))
}

func stringOutput(command *exec.Cmd) (string, error) {
	output, err := command.CombinedOutput()
	return string(output), err
}

func collectCronJobs(ctx context.Context, hostRoot string) []model.CronJob {
	if runtime.GOOS == "windows" {
		output, err := runHostCommand(ctx, hostRoot, "schtasks.exe", "/Query", "/FO", "CSV", "/NH")
		if err != nil {
			return []model.CronJob{}
		}
		return parseWindowsTasks(output)
	}
	if runtime.GOOS != "linux" {
		return []model.CronJob{}
	}
	paths := make([]string, 0, 32)
	for _, candidate := range []string{"/etc/crontab", "/etc/cron.d/*", "/var/spool/cron/crontabs/*", "/var/spool/cron/*"} {
		pattern := candidate
		if strings.TrimSpace(hostRoot) != "" {
			pattern = filepath.Join(filepath.Clean(hostRoot), strings.TrimPrefix(filepath.Clean(candidate), string(filepath.Separator)))
		}
		matches, _ := filepath.Glob(pattern)
		paths = append(paths, matches...)
	}
	result := make([]model.CronJob, 0, minInt(len(paths), 128))
	seen := make(map[string]struct{})
	for _, path := range paths {
		if len(result) >= 256 {
			break
		}
		if _, ok := seen[path]; ok {
			continue
		}
		seen[path] = struct{}{}
		data, err := os.ReadFile(path)
		if err != nil || len(data) > 256*1024 {
			continue
		}
		systemFile := strings.Contains(path, string(filepath.Separator)+"etc"+string(filepath.Separator))
		user := ""
		if !systemFile {
			user = filepath.Base(path)
		}
		for _, line := range strings.Split(string(data), "\n") {
			if ctx.Err() != nil || len(result) >= 256 {
				break
			}
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			fields := strings.Fields(line)
			if len(fields) > 0 && strings.Contains(fields[0], "=") {
				continue
			}
			scheduleEnd := 5
			if strings.HasPrefix(fields[0], "@") {
				scheduleEnd = 1
			}
			minimum := scheduleEnd + 1
			if systemFile {
				minimum++
			}
			if len(fields) < minimum {
				continue
			}
			if systemFile {
				if len(fields) <= scheduleEnd+1 {
					continue
				}
				user = fields[scheduleEnd]
			}
			commandStart := scheduleEnd
			if systemFile {
				commandStart++
			}
			if len(fields) <= commandStart {
				continue
			}
			result = append(result, model.CronJob{Source: path, User: user, Schedule: strings.Join(fields[:scheduleEnd], " "), Command: redactCronCommand(strings.Join(fields[commandStart:], " "))})
		}
	}
	return result
}

func parseWindowsTasks(output string) []model.CronJob {
	reader := csv.NewReader(strings.NewReader(output))
	reader.FieldsPerRecord = -1
	rows := make([][]string, 0, 128)
	for {
		line, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil || len(line) < 2 || strings.TrimSpace(line[0]) == "" {
			continue
		}
		rows = append(rows, line)
		if len(rows) >= 256 {
			break
		}
	}
	result := make([]model.CronJob, 0, len(rows))
	for _, row := range rows {
		result = append(result, model.CronJob{Source: "Task Scheduler", Schedule: row[1], Command: redactCronCommand(row[0])})
	}
	return result
}

func redactCronCommand(value string) string {
	value = cronSecretPattern.ReplaceAllString(value, "$1=***")
	value = cronSecretArgPattern.ReplaceAllStringFunc(value, func(match string) string {
		separator := strings.IndexAny(match, "= \t")
		if separator < 0 {
			return match
		}
		return match[:separator+1] + "***"
	})
	if len(value) > 500 {
		return value[:500]
	}
	return value
}

func collectLogs(ctx context.Context, paths []string, hostRoot string) []model.LogFile {
	result := make([]model.LogFile, 0, minInt(len(paths), 32))
	for _, raw := range paths {
		if ctx.Err() != nil || len(result) >= 64 {
			break
		}
		raw = strings.TrimSpace(raw)
		if !filepath.IsAbs(raw) {
			continue
		}
		path := hostPath(hostRoot, raw)
		if path == "" {
			continue
		}
		info, err := os.Stat(path)
		if err != nil || !info.Mode().IsRegular() || info.Size() > 50*1024*1024 {
			continue
		}
		file, err := os.Open(path)
		if err != nil {
			continue
		}
		start := info.Size() - 32*1024
		if start < 0 {
			start = 0
		}
		_, _ = file.Seek(start, io.SeekStart)
		data, readErr := io.ReadAll(io.LimitReader(file, 32*1024))
		_ = file.Close()
		if readErr != nil {
			continue
		}
		result = append(result, model.LogFile{Path: raw, SizeBytes: info.Size(), ModifiedAt: info.ModTime().UTC().Format(time.RFC3339Nano), Lines: tailLines(string(data), 20)})
	}
	return result
}

func collectSystemLogs(ctx context.Context, enabled bool, hostRoot string) []model.LogFile {
	if !enabled || runtime.GOOS != "linux" {
		return []model.LogFile{}
	}
	return collectLogs(ctx, []string{"/var/log/syslog", "/var/log/messages", "/var/log/auth.log", "/var/log/secure"}, hostRoot)
}

func tailLines(value string, limit int) []string {
	parts := strings.Split(strings.TrimRight(value, "\r\n"), "\n")
	if len(parts) > limit {
		parts = parts[len(parts)-limit:]
	}
	result := make([]string, 0, len(parts))
	for _, line := range parts {
		line = strings.TrimRight(line, "\r")
		if len(line) > 500 {
			line = line[:500]
		}
		result = append(result, line)
	}
	return result
}

func collectIntegrity(ctx context.Context, paths []string, hostRoot string) []model.IntegrityItem {
	result := make([]model.IntegrityItem, 0, minInt(len(paths), 128))
	for _, raw := range paths {
		if ctx.Err() != nil || len(result) >= 512 {
			break
		}
		raw = strings.TrimSpace(raw)
		if !filepath.IsAbs(raw) {
			continue
		}
		path := hostPath(hostRoot, raw)
		if path == "" {
			continue
		}
		info, err := os.Stat(path)
		if err != nil {
			continue
		}
		if info.IsDir() {
			_ = filepath.WalkDir(path, func(filePath string, entry os.DirEntry, walkErr error) error {
				if ctx.Err() != nil || len(result) >= 512 {
					return context.Canceled
				}
				if walkErr != nil || entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
					return nil
				}
				item, ok := hashIntegrityFile(ctx, filePath, filepath.Join(raw, strings.TrimPrefix(filePath, path)))
				if ok {
					result = append(result, item)
				}
				return nil
			})
			continue
		}
		if item, ok := hashIntegrityFile(ctx, path, raw); ok {
			result = append(result, item)
		}
	}
	return result
}

func hashIntegrityFile(ctx context.Context, path, display string) (model.IntegrityItem, bool) {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > 16*1024*1024 {
		return model.IntegrityItem{}, false
	}
	file, err := os.Open(path)
	if err != nil {
		return model.IntegrityItem{}, false
	}
	defer file.Close()
	hash := sha256.New()
	buffer := make([]byte, 64*1024)
	for {
		if ctx.Err() != nil {
			return model.IntegrityItem{}, false
		}
		count, readErr := file.Read(buffer)
		if count > 0 {
			_, _ = hash.Write(buffer[:count])
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			return model.IntegrityItem{}, false
		}
	}
	return model.IntegrityItem{Path: display, SHA256: hex.EncodeToString(hash.Sum(nil)), SizeBytes: info.Size(), ModifiedAt: info.ModTime().UTC().Format(time.RFC3339Nano)}, true
}

func minInt(value, maximum int) int {
	if value < 0 {
		return 0
	}
	if value > maximum {
		return maximum
	}
	return value
}
