package collector

import (
	"context"
	"math"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"xingchen-monitor/agent/internal/model"
)

// The command runner deliberately uses exec.CommandContext directly. Shell
// expansion, pipelines and redirects are not part of the custom metric API.

const (
	maxCustomMetricCount     = 32
	maxCustomMetricName      = 80
	maxCustomMetricCommand   = 128
	maxCustomMetricArgs      = 16
	maxCustomMetricArgLength = 256
	maxCustomMetricOutput    = 4096
	customMetricTimeout      = 3 * time.Second
)

type CustomMetricConfig struct {
	Name    string
	Command string
	Args    []string
	Kind    string
}

func collectCustomMetrics(parent context.Context, configs []CustomMetricConfig) []model.CustomMetricResult {
	result := make([]model.CustomMetricResult, 0, len(configs))
	for _, config := range configs {
		ctx, cancel := context.WithTimeout(parent, customMetricTimeout)
		command := exec.CommandContext(ctx, config.Command, config.Args...)
		output, err := command.Output()
		exitCode := 0
		if err != nil {
			if exitError, ok := err.(*exec.ExitError); ok {
				exitCode = exitError.ExitCode()
			} else if ctx.Err() != nil {
				exitCode = -1
			} else {
				exitCode = -1
			}
		}
		text := trimCustomOutput(string(output))
		item := model.CustomMetricResult{Name: config.Name, Kind: config.Kind, ExitCode: exitCode, Success: err == nil}
		switch config.Kind {
		case "number":
			if err == nil {
				if value, parseErr := strconv.ParseFloat(strings.TrimSpace(text), 64); parseErr == nil && !math.IsNaN(value) && !math.IsInf(value, 0) {
					item.Value = &value
				} else {
					item.Success = false
					item.Error = "输出不是有效数值"
				}
			}
		case "exit_code":
			value := float64(exitCode)
			item.Value = &value
		default:
			item.Text = text
		}
		if err != nil && item.Error == "" {
			item.Error = trimCustomOutput(err.Error())
		}
		result = append(result, item)
		cancel()
	}
	return result
}

func trimCustomOutput(value string) string {
	value = strings.TrimSpace(value)
	runes := []rune(value)
	if len(runes) > maxCustomMetricOutput {
		return string(runes[:maxCustomMetricOutput])
	}
	return value
}
