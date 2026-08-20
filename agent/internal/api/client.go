package api

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"time"
)

type Client struct {
	endpoint string
	deviceID string
	agentKey string
	http     *http.Client
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
	request.Header.Set("X-Device-Id", c.deviceID)
	request.Header.Set("X-Agent-Key", c.agentKey)
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
