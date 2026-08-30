package collector

import "testing"

func TestParseSmartctlNvmeHealth(t *testing.T) {
	result := parseSmartctlReport([]byte(`{
  "smart_status": {"passed": true},
  "nvme_smart_health_information_log": {
    "critical_warning": 0,
    "temperature": 42,
    "percentage_used": 7,
    "power_on_hours": 1234,
    "media_errors": 2,
    "unsafe_shutdowns": 3
  }
}`), nil)
	if result.Status != "PASSED" || result.Temperature != 42 || result.PercentageUsed != 7 || result.PowerOnHours != 1234 || result.MediaErrors != 2 {
		t.Fatalf("unexpected SMART result: %#v", result)
	}
}

func TestParseSmartctlFailureAndUnknown(t *testing.T) {
	failed := parseSmartctlReport([]byte(`{"smart_status":{"passed":false}}`), nil)
	if failed.Status != "FAILED" {
		t.Fatalf("status = %q, want FAILED", failed.Status)
	}
	unknown := parseSmartctlReport(nil, errTestSmartctl)
	if unknown.Status != "UNKNOWN" {
		t.Fatalf("status = %q, want UNKNOWN", unknown.Status)
	}
}

var errTestSmartctl = testError("smartctl unavailable")

type testError string

func (e testError) Error() string { return string(e) }
