package api

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
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
