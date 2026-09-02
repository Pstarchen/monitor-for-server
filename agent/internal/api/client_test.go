package api

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"xingchen-monitor/agent/internal/model"
)

func TestClientSendsDeviceCredentialsAndPayload(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.Header.Get("X-Device-Id") != "device-1" || request.Header.Get("X-Agent-Key") != "agent-key" {
			t.Error("missing agent credentials")
		}
		body, _ := io.ReadAll(request.Body)
		if string(body) != `{"ok":true}` {
			t.Errorf("unexpected payload: %s", body)
		}
		response.WriteHeader(http.StatusAccepted)
	}))
	defer server.Close()

	client := NewClient(server.URL, "device-1", "agent-key", time.Second)
	if err := client.Send(context.Background(), []byte(`{"ok":true}`)); err != nil {
		t.Fatal(err)
	}
}

func TestClientPollsAndSubmitsTaskResults(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/api/agent/v1/tasks/next" {
			if request.Header.Get("X-Device-Id") != "device-1" || request.Header.Get("X-Agent-Key") != "agent-key" {
				t.Error("missing task credentials")
			}
			response.Header().Set("Content-Type", "application/json")
			_, _ = response.Write([]byte(`{"id":7,"command":"printf","args":["ok"],"timeoutSeconds":2,"maxOutputBytes":1024}`))
			return
		}
		if request.URL.Path != "/api/agent/v1/tasks/7/result" || request.Method != http.MethodPost {
			t.Errorf("unexpected request %s %s", request.Method, request.URL.Path)
		}
		response.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	client := NewClient(server.URL, "device-1", "agent-key", time.Second)
	task, err := client.PollTask(context.Background())
	if err != nil || task == nil || task.ID != 7 {
		t.Fatalf("poll task = %#v, err = %v", task, err)
	}
	if err := client.SendTaskResult(context.Background(), task.ID, model.TaskResult{Status: "SUCCEEDED"}); err != nil {
		t.Fatal(err)
	}
}

func TestClientReadsIntervalFromReportResponse(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		response.Header().Set(AgentIntervalHeader, "10")
		response.WriteHeader(http.StatusAccepted)
	}))
	defer server.Close()

	client := NewClient(server.URL, "device-1", "agent-key", time.Second)
	interval, err := client.SendWithInterval(context.Background(), []byte(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	if interval != 10*time.Second {
		t.Fatalf("interval = %s, want 10s", interval)
	}
}
