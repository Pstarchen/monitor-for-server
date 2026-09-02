package worker

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"xingchen-monitor/agent/internal/api"
	"xingchen-monitor/agent/internal/model"
)

func TestSendTaskResultRetriesTransientHTTPFailures(t *testing.T) {
	var attempts atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		if attempts.Add(1) < 3 {
			response.WriteHeader(http.StatusBadGateway)
			return
		}
		response.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	client := api.NewClient(server.URL, "device", "key", time.Second)
	if err := sendTaskResult(context.Background(), client, 1, model.TaskResult{Status: "SUCCEEDED"}); err != nil {
		t.Fatal(err)
	}
	if got := attempts.Load(); got != 3 {
		t.Fatalf("attempts = %d, want 3", got)
	}
}

func TestSendTaskResultDoesNotRetryPermanentHTTPFailures(t *testing.T) {
	var attempts atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		attempts.Add(1)
		response.WriteHeader(http.StatusBadRequest)
	}))
	defer server.Close()

	client := api.NewClient(server.URL, "device", "key", time.Second)
	if err := sendTaskResult(context.Background(), client, 1, model.TaskResult{Status: "SUCCEEDED"}); err == nil {
		t.Fatal("expected permanent HTTP failure")
	}
	if got := attempts.Load(); got != 1 {
		t.Fatalf("attempts = %d, want 1", got)
	}
}
