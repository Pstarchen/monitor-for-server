package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"guanlan-monitor/agent/internal/model"
)

type Client struct {
	endpoint string
	deviceID string
	agentKey string
	http     *http.Client
}

type HTTPStatusError struct {
	Operation  string
	StatusCode int
}

func (e *HTTPStatusError) Error() string {
	return fmt.Sprintf("%s returned HTTP %d", e.Operation, e.StatusCode)
}

func (c *Client) PollTask(ctx context.Context) (*model.TaskAssignment, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimSuffix(c.endpoint, "/reports")+"/tasks/next", nil)
	if err != nil {
		return nil, err
	}
	c.setCredentials(request)
	response, err := c.http.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusNoContent {
		return nil, nil
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, &HTTPStatusError{Operation: "task poll", StatusCode: response.StatusCode}
	}
	var task model.TaskAssignment
	if err := json.NewDecoder(io.LimitReader(response.Body, 2<<20)).Decode(&task); err != nil {
		return nil, err
	}
	return &task, nil
}

func (c *Client) SendTaskResult(ctx context.Context, taskID int64, result model.TaskResult) error {
	body, err := json.Marshal(result)
	if err != nil {
		return err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, fmt.Sprintf("%s/tasks/%d/result", strings.TrimSuffix(c.endpoint, "/reports"), taskID), bytes.NewReader(body))
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/json")
	c.setCredentials(request)
	response, err := c.http.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return &HTTPStatusError{Operation: "task result", StatusCode: response.StatusCode}
	}
	return nil
}

func (c *Client) setCredentials(request *http.Request) {
	request.Header.Set("X-Device-Id", c.deviceID)
	request.Header.Set("X-Agent-Key", c.agentKey)
}

const AgentIntervalHeader = "X-Agent-Interval-Seconds"

func NewClient(serverURL, deviceID, agentKey string, timeout time.Duration) *Client {
	return &Client{
		endpoint: serverURL + "/api/agent/v1/reports",
		deviceID: deviceID,
		agentKey: agentKey,
		http:     &http.Client{Timeout: timeout},
	}
}

func (c *Client) Send(ctx context.Context, payload []byte) error {
	_, err := c.SendWithInterval(ctx, payload)
	return err
}

func (c *Client) SendWithInterval(ctx context.Context, payload []byte) (time.Duration, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, c.endpoint, bytes.NewReader(payload))
	if err != nil {
		return 0, err
	}
	request.Header.Set("Content-Type", "application/json")
	c.setCredentials(request)
	response, err := c.http.Do(request)
	if err != nil {
		return 0, err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return 0, fmt.Errorf("server returned HTTP %d", response.StatusCode)
	}
	seconds := response.Header.Get(AgentIntervalHeader)
	if seconds == "" {
		return 0, nil
	}
	value, err := time.ParseDuration(seconds + "s")
	if err != nil || value < time.Second || value > time.Minute {
		return 0, nil
	}
	return value, nil
}
