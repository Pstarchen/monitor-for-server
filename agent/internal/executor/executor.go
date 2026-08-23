package executor

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"guanlan-monitor/agent/internal/model"
)

type Result struct {
	Status   string
	ExitCode *int
	Stdout   string
	Stderr   string
	Error    string
}

func Run(ctx context.Context, task model.TaskAssignment, outputLimit int, allowCommandExecution bool, allowFileOperations bool, hostRoot string) Result {
	if task.Command == "" || outputLimit < 1 {
		return Result{Status: "FAILED", Error: "invalid task"}
	}
	if task.TimeoutSeconds < 1 {
		return Result{Status: "FAILED", Error: "invalid task timeout"}
	}
	if task.Operation != "" && task.Operation != "COMMAND" {
		if !allowFileOperations {
			return Result{Status: "FAILED", Error: "file operations disabled"}
		}
		taskContext, cancel := context.WithTimeout(ctx, time.Duration(task.TimeoutSeconds)*time.Second)
		defer cancel()
		return runFile(taskContext, task, outputLimit, hostRoot)
	}
	if !allowCommandExecution {
		return Result{Status: "FAILED", Error: "command execution disabled"}
	}
	if task.MaxOutputBytes > 0 && task.MaxOutputBytes < outputLimit {
		outputLimit = task.MaxOutputBytes
	}
	taskContext, cancel := context.WithTimeout(ctx, time.Duration(task.TimeoutSeconds)*time.Second)
	defer cancel()
	command := exec.CommandContext(taskContext, task.Command, task.Args...)
	configureCommand(command)
	stdout := &limitedBuffer{limit: outputLimit}
	stderr := &limitedBuffer{limit: outputLimit}
	command.Stdout = stdout
	command.Stderr = stderr
	err := runWithCancellation(taskContext, command)
	result := Result{Status: "SUCCEEDED", Stdout: stdout.String(), Stderr: stderr.String()}
	if errors.Is(taskContext.Err(), context.DeadlineExceeded) {
		result.Status = "TIMED_OUT"
		result.Error = "command timed out"
		return result
	}
	if err == nil {
		code := 0
		result.ExitCode = &code
		return result
	}
	result.Status = "FAILED"
	result.Error = err.Error()
	var exitError *exec.ExitError
	if errors.As(err, &exitError) {
		code := exitError.ExitCode()
		result.ExitCode = &code
	}
	return result
}

type filePayload struct {
	Path          string `json:"path"`
	Offset        int64  `json:"offset"`
	Length        int64  `json:"length"`
	Encoding      string `json:"encoding"`
	Content       string `json:"content"`
	ShowHidden    bool   `json:"showHidden"`
	Recursive     bool   `json:"recursive"`
	CreateDirs    bool   `json:"createDirs"`
	Mode          string `json:"mode"`
	IfMatchSHA256 string `json:"ifMatchSha256"`
}

type fileEntry struct {
	Name       string `json:"name"`
	Type       string `json:"type"`
	Size       int64  `json:"size"`
	Mode       string `json:"mode"`
	ModifiedAt string `json:"modifiedAt"`
}

type fileResponse struct {
	Operation string      `json:"operation"`
	Path      string      `json:"path"`
	Entries   []fileEntry `json:"entries,omitempty"`
	Content   string      `json:"content,omitempty"`
	Encoding  string      `json:"encoding,omitempty"`
	Size      int64       `json:"size,omitempty"`
	SHA256    string      `json:"sha256,omitempty"`
}

func runFile(ctx context.Context, task model.TaskAssignment, outputLimit int, hostRoot string) Result {
	if task.MaxOutputBytes > 0 && task.MaxOutputBytes < outputLimit {
		outputLimit = task.MaxOutputBytes
	}
	var payload filePayload
	if len(task.Payload) == 0 || json.Unmarshal(task.Payload, &payload) != nil {
		return Result{Status: "FAILED", Error: "invalid file task payload"}
	}
	path, err := resolvePath(payload.Path, hostRoot)
	if err != nil {
		return Result{Status: "FAILED", Error: err.Error()}
	}
	select {
	case <-ctx.Done():
		return Result{Status: "TIMED_OUT", Error: "task canceled"}
	default:
	}
	var response fileResponse
	switch task.Operation {
	case "FILE_LIST":
		response, err = listFile(ctx, path, payload)
	case "FILE_READ":
		response, err = readFile(ctx, path, payload)
	case "FILE_WRITE":
		response, err = writeFile(ctx, path, payload)
	case "FILE_DELETE":
		response, err = deleteFile(ctx, path, payload)
	default:
		return Result{Status: "FAILED", Error: "unsupported file operation"}
	}
	if err != nil {
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return Result{Status: "TIMED_OUT", Error: "file task timed out"}
		}
		return Result{Status: "FAILED", Error: trimError(err)}
	}
	encoded, err := json.Marshal(response)
	if err != nil {
		return Result{Status: "FAILED", Error: "file result encoding failed"}
	}
	if len(encoded) > outputLimit {
		return Result{Status: "FAILED", Error: "file result exceeds output limit"}
	}
	return Result{Status: "SUCCEEDED", Stdout: string(encoded)}
}

func resolvePath(raw, hostRoot string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" || strings.IndexByte(raw, 0) >= 0 {
		return "", errors.New("invalid file path")
	}
	root := ""
	if strings.TrimSpace(hostRoot) != "" {
		root, _ = filepath.Abs(filepath.Clean(hostRoot))
	}
	var target string
	if root != "" {
		clean := filepath.Clean(raw)
		if filepath.IsAbs(clean) {
			clean = strings.TrimLeft(clean, `/\\`)
		}
		target = filepath.Join(root, clean)
	} else {
		if !filepath.IsAbs(raw) {
			return "", errors.New("file path must be absolute")
		}
		target = filepath.Clean(raw)
	}
	if root != "" {
		rel, err := filepath.Rel(root, target)
		if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
			return "", errors.New("file path escapes host root")
		}
		if rel == "." {
			return "", errors.New("host root itself is not an allowed file target")
		}
		resolved, evalErr := filepath.EvalSymlinks(target)
		if evalErr == nil {
			if !pathWithinRoot(root, resolved) {
				return "", errors.New("file path escapes host root through symlink")
			}
		} else if !errors.Is(evalErr, os.ErrNotExist) {
			return "", evalErr
		} else {
			parent, parentErr := filepath.EvalSymlinks(filepath.Dir(target))
			if parentErr == nil && !pathWithinRoot(root, parent) {
				return "", errors.New("file path escapes host root through symlink")
			}
		}
	}
	return target, nil
}

func pathWithinRoot(root, target string) bool {
	rel, err := filepath.Rel(root, target)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && !filepath.IsAbs(rel)
}

func listFile(ctx context.Context, path string, payload filePayload) (fileResponse, error) {
	entries, err := os.ReadDir(path)
	if err != nil {
		return fileResponse{}, err
	}
	result := fileResponse{Operation: "FILE_LIST", Path: payload.Path, Entries: make([]fileEntry, 0, len(entries))}
	for _, entry := range entries {
		if err := ctx.Err(); err != nil {
			return fileResponse{}, err
		}
		if !payload.ShowHidden && strings.HasPrefix(entry.Name(), ".") {
			continue
		}
		info, infoErr := entry.Info()
		if infoErr != nil {
			continue
		}
		typeName := "file"
		if info.IsDir() {
			typeName = "directory"
		} else if info.Mode()&os.ModeSymlink != 0 {
			typeName = "symlink"
		}
		result.Entries = append(result.Entries, fileEntry{Name: entry.Name(), Type: typeName, Size: info.Size(), Mode: info.Mode().String(), ModifiedAt: info.ModTime().UTC().Format(time.RFC3339Nano)})
		if len(result.Entries) >= 4096 {
			break
		}
	}
	return result, nil
}

func readFile(ctx context.Context, path string, payload filePayload) (fileResponse, error) {
	if payload.Offset < 0 {
		return fileResponse{}, errors.New("invalid file offset")
	}
	length := payload.Length
	if length <= 0 {
		length = 65536
	}
	if length > 1<<20 {
		length = 1 << 20
	}
	file, err := os.Open(path)
	if err != nil {
		return fileResponse{}, err
	}
	defer file.Close()
	if _, err = file.Seek(payload.Offset, io.SeekStart); err != nil {
		return fileResponse{}, err
	}
	data, err := readContext(ctx, io.LimitReader(file, length))
	if err != nil {
		return fileResponse{}, err
	}
	encoding := strings.ToLower(payload.Encoding)
	if encoding == "" {
		encoding = "utf8"
	}
	content := string(data)
	if encoding == "base64" {
		content = base64.StdEncoding.EncodeToString(data)
	} else if encoding != "utf8" {
		return fileResponse{}, errors.New("unsupported file encoding")
	}
	hash, err := hashFile(ctx, path)
	if err != nil {
		return fileResponse{}, err
	}
	return fileResponse{Operation: "FILE_READ", Path: payload.Path, Content: content, Encoding: encoding, Size: int64(len(data)), SHA256: hash}, nil
}

func writeFile(ctx context.Context, path string, payload filePayload) (fileResponse, error) {
	if err := ctx.Err(); err != nil {
		return fileResponse{}, err
	}
	data, err := decodeContent(payload.Content, payload.Encoding)
	if err != nil {
		return fileResponse{}, err
	}
	if payload.IfMatchSHA256 != "" {
		current, readErr := os.ReadFile(path)
		if readErr != nil && !errors.Is(readErr, os.ErrNotExist) {
			return fileResponse{}, readErr
		}
		currentHash := sha256.Sum256(current)
		if !strings.EqualFold(hex.EncodeToString(currentHash[:]), payload.IfMatchSHA256) {
			return fileResponse{}, errors.New("file changed since the supplied sha256")
		}
	}
	if payload.CreateDirs {
		if err = os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return fileResponse{}, err
		}
	}
	if err := ctx.Err(); err != nil {
		return fileResponse{}, err
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".guanlan-write-*")
	if err != nil {
		return fileResponse{}, err
	}
	temp := file.Name()
	defer os.Remove(temp)
	mode := parseMode(payload.Mode)
	if payload.Mode == "" {
		if info, statErr := os.Stat(path); statErr == nil {
			mode = info.Mode().Perm()
		}
	}
	if _, err = writeContext(ctx, file, data); err == nil {
		err = file.Chmod(mode)
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return fileResponse{}, err
	}
	if err := ctx.Err(); err != nil {
		return fileResponse{}, err
	}
	if err = replaceFile(temp, path); err != nil {
		return fileResponse{}, err
	}
	hash := sha256.Sum256(data)
	return fileResponse{Operation: "FILE_WRITE", Path: payload.Path, Size: int64(len(data)), SHA256: hex.EncodeToString(hash[:])}, nil
}

func deleteFile(ctx context.Context, path string, payload filePayload) (fileResponse, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return fileResponse{}, err
	}
	if info.IsDir() {
		if !payload.Recursive {
			return fileResponse{}, errors.New("directory requires recursive=true")
		}
		err = removeTree(ctx, path)
	} else {
		err = os.Remove(path)
	}
	if err != nil {
		return fileResponse{}, err
	}
	return fileResponse{Operation: "FILE_DELETE", Path: payload.Path}, nil
}

func decodeContent(content, encoding string) ([]byte, error) {
	if strings.ToLower(encoding) == "base64" {
		data, err := base64.StdEncoding.DecodeString(content)
		if err != nil {
			return nil, errors.New("invalid base64 content")
		}
		return data, nil
	}
	if encoding == "" || strings.EqualFold(encoding, "utf8") {
		return []byte(content), nil
	}
	return nil, errors.New("unsupported file encoding")
}

func hashFile(ctx context.Context, path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err = copyContext(ctx, hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func readContext(ctx context.Context, reader io.Reader) ([]byte, error) {
	var result bytes.Buffer
	buffer := make([]byte, 64*1024)
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		count, err := reader.Read(buffer)
		if count > 0 {
			_, _ = result.Write(buffer[:count])
		}
		if err == io.EOF {
			return result.Bytes(), nil
		}
		if err != nil {
			return nil, err
		}
	}
}

func writeContext(ctx context.Context, writer io.Writer, data []byte) (int, error) {
	total := 0
	for total < len(data) {
		if err := ctx.Err(); err != nil {
			return total, err
		}
		end := total + 64*1024
		if end > len(data) {
			end = len(data)
		}
		count, err := writer.Write(data[total:end])
		total += count
		if err != nil {
			return total, err
		}
		if count == 0 {
			return total, io.ErrShortWrite
		}
	}
	return total, nil
}

func copyContext(ctx context.Context, dst io.Writer, src io.Reader) (int64, error) {
	var total int64
	buffer := make([]byte, 64*1024)
	for {
		if err := ctx.Err(); err != nil {
			return total, err
		}
		count, err := src.Read(buffer)
		if count > 0 {
			written, writeErr := dst.Write(buffer[:count])
			total += int64(written)
			if writeErr != nil {
				return total, writeErr
			}
			if written != count {
				return total, io.ErrShortWrite
			}
		}
		if err == io.EOF {
			return total, nil
		}
		if err != nil {
			return total, err
		}
	}
}

func removeTree(ctx context.Context, path string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return os.Remove(path)
	}
	entries, err := os.ReadDir(path)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if err := removeTree(ctx, filepath.Join(path, entry.Name())); err != nil {
			return err
		}
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	return os.Remove(path)
}

func parseMode(value string) os.FileMode {
	if value == "" {
		return 0o644
	}
	parsed, err := strconv.ParseUint(strings.TrimPrefix(value, "0"), 8, 32)
	if err != nil {
		return 0o644
	}
	return os.FileMode(parsed)
}

func trimError(err error) string {
	if err == nil {
		return ""
	}
	value := err.Error()
	if len(value) > 500 {
		return value[:500]
	}
	return value
}

type limitedBuffer struct {
	bytes.Buffer
	limit     int
	truncated bool
}

func (b *limitedBuffer) Write(value []byte) (int, error) {
	remaining := b.limit - b.Len()
	if remaining <= 0 {
		b.truncated = true
		return len(value), nil
	}
	if len(value) > remaining {
		_, _ = b.Buffer.Write(value[:remaining])
		b.truncated = true
		return len(value), nil
	}
	return b.Buffer.Write(value)
}
