package model

import "encoding/json"

type TaskAssignment struct {
	ID             int64           `json:"id"`
	Operation      string          `json:"operation,omitempty"`
	Command        string          `json:"command"`
	Args           []string        `json:"args"`
	TimeoutSeconds int             `json:"timeoutSeconds"`
	MaxOutputBytes int             `json:"maxOutputBytes"`
	Payload        json.RawMessage `json:"payload,omitempty"`
}

type TaskResult struct {
	Status   string `json:"status"`
	ExitCode *int   `json:"exitCode,omitempty"`
	Stdout   string `json:"stdout,omitempty"`
	Stderr   string `json:"stderr,omitempty"`
	Error    string `json:"error,omitempty"`
}
