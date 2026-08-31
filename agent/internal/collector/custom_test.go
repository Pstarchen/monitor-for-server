package collector

import (
	"context"
	"runtime"
	"testing"
)

func TestCollectCustomNumericMetric(t *testing.T) {
	command, args := "printf", []string{"42.5"}
	if runtime.GOOS == "windows" {
		command, args = "cmd.exe", []string{"/c", "echo 42.5"}
	}
	values := collectCustomMetrics(context.Background(), []CustomMetricConfig{{Name: "queue", Command: command, Args: args, Kind: "number"}})
	if len(values) != 1 || values[0].Value == nil || *values[0].Value != 42.5 || !values[0].Success {
		t.Fatalf("custom metric = %#v", values)
	}
}

func TestCollectCustomExitCodeMetric(t *testing.T) {
	command, args := "sh", []string{"-c", "exit 7"}
	if runtime.GOOS == "windows" {
		command, args = "cmd.exe", []string{"/c", "exit /b 7"}
	}
	values := collectCustomMetrics(context.Background(), []CustomMetricConfig{{Name: "exit", Command: command, Args: args, Kind: "exit_code"}})
	if len(values) != 1 || values[0].Value == nil || *values[0].Value != 7 || values[0].Success {
		t.Fatalf("custom exit metric = %#v", values)
	}
}

func TestCollectCustomNumericMetricRejectsNonFiniteValues(t *testing.T) {
	values := []string{"NaN", "+Inf"}
	for _, output := range values {
		command, args := "printf", []string{output}
		if runtime.GOOS == "windows" {
			command, args = "cmd.exe", []string{"/c", "echo " + output}
		}
		result := collectCustomMetrics(context.Background(), []CustomMetricConfig{{Name: "invalid", Command: command, Args: args, Kind: "number"}})
		if len(result) != 1 || result[0].Success || result[0].Value != nil {
			t.Fatalf("custom metric %q = %#v", output, result)
		}
	}
}
