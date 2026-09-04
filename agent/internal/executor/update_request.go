package executor

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"xingchen-monitor/agent/internal/model"
)

var stableAgentVersion = regexp.MustCompile(`^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$`)
var requestTrigger = triggerAgentUpdate

func runAgentUpdate(ctx context.Context, task model.TaskAssignment, requestPath, launcherPath string) Result {
	if strings.TrimSpace(requestPath) == "" {
		return Result{Status: "FAILED", Error: "agent update requests disabled"}
	}
	if task.Command != model.TaskCommandAgentUpdate || len(task.Args) != 0 {
		return Result{Status: "FAILED", Error: "invalid agent update task"}
	}
	payload, err := parseAgentUpdatePayload(task.Payload)
	if err != nil {
		return Result{Status: "FAILED", Error: "invalid agent update payload"}
	}
	if err := ctx.Err(); err != nil {
		return Result{Status: "TIMED_OUT", Error: "task canceled"}
	}
	if err := publishAgentUpdateRequest(requestPath, payload); err != nil {
		if errors.Is(err, os.ErrExist) {
			return Result{Status: "FAILED", Error: "agent update request already pending"}
		}
		return Result{Status: "FAILED", Error: "agent update request could not be queued"}
	}
	if err := requestTrigger(launcherPath); err != nil {
		_ = os.Remove(requestPath)
		return Result{Status: "FAILED", Error: "agent update request could not be triggered"}
	}
	return Result{Status: "SUCCEEDED", Stdout: `{"status":"ACCEPTED"}`}
}

func parseAgentUpdatePayload(raw json.RawMessage) (model.AgentUpdatePayload, error) {
	if len(raw) == 0 || len(raw) > 1024 {
		return model.AgentUpdatePayload{}, errors.New("invalid payload size")
	}
	var payload model.AgentUpdatePayload
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&payload); err != nil {
		return model.AgentUpdatePayload{}, err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return model.AgentUpdatePayload{}, errors.New("trailing payload content")
	}
	if payload.Action != "update" && payload.Action != "rollback" {
		return model.AgentUpdatePayload{}, errors.New("unsupported update action")
	}
	if len(payload.Version) > 64 || !stableAgentVersion.MatchString(payload.Version) {
		return model.AgentUpdatePayload{}, errors.New("invalid update version")
	}
	if (payload.RolloutID == nil) != (payload.MemberID == nil) {
		return model.AgentUpdatePayload{}, errors.New("rollout identifiers must be paired")
	}
	if payload.RolloutID != nil && (*payload.RolloutID < 1 || *payload.MemberID < 1) {
		return model.AgentUpdatePayload{}, errors.New("invalid rollout identifiers")
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return model.AgentUpdatePayload{}, err
	}
	for _, name := range []string{"rolloutId", "memberId"} {
		if value, present := fields[name]; present && bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return model.AgentUpdatePayload{}, errors.New("null rollout identifier")
		}
	}
	return payload, nil
}

func publishAgentUpdateRequest(path string, payload model.AgentUpdatePayload) error {
	directory := filepath.Dir(path)
	info, err := os.Stat(directory)
	if err != nil || !info.IsDir() {
		return errors.New("request directory unavailable")
	}
	temporary, err := os.CreateTemp(directory, ".update-request-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)

	rolloutID, memberID := "", ""
	if payload.RolloutID != nil {
		rolloutID = strconv.FormatInt(*payload.RolloutID, 10)
		memberID = strconv.FormatInt(*payload.MemberID, 10)
	}
	_, writeErr := fmt.Fprintf(temporary, "action=%s\nversion=%s\nrollout_id=%s\nmember_id=%s\n", payload.Action, payload.Version, rolloutID, memberID)
	if writeErr == nil {
		writeErr = temporary.Sync()
	}
	if closeErr := temporary.Close(); writeErr == nil {
		writeErr = closeErr
	}
	if writeErr != nil {
		return writeErr
	}
	if err := os.Link(temporaryPath, path); err != nil {
		return err
	}
	return nil
}
