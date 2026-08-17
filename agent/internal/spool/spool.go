package spool

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

type Queue struct {
	dir      string
	maxItems int
	mu       sync.Mutex
}

func New(dir string, maxItems int) (*Queue, error) {
	if strings.TrimSpace(dir) == "" {
		return nil, errors.New("spool directory is required")
	}
	if maxItems <= 0 {
		return nil, errors.New("maxItems must be positive")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	return &Queue{dir: dir, maxItems: maxItems}, nil
}

func (q *Queue) Enqueue(payload []byte) error {
	q.mu.Lock()
	defer q.mu.Unlock()
	if err := q.trimLocked(q.maxItems - 1); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(q.dir, ".pending-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(payload); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	name := fmt.Sprintf("%020d-%s.json", time.Now().UnixNano(), filepath.Base(temporaryPath))
	return os.Rename(temporaryPath, filepath.Join(q.dir, name))
}

func (q *Queue) List() ([]string, error) {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.listLocked()
}

func (q *Queue) Remove(path string) error {
	q.mu.Lock()
	defer q.mu.Unlock()
	absDir, err := filepath.Abs(q.dir)
	if err != nil {
		return err
	}
	absPath, err := filepath.Abs(path)
	if err != nil {
		return err
	}
	if filepath.Dir(absPath) != absDir {
		return errors.New("refusing to remove a file outside the spool directory")
	}
	return os.Remove(absPath)
}

func (q *Queue) trimLocked(keep int) error {
	paths, err := q.listLocked()
	if err != nil {
		return err
	}
	for len(paths) > keep {
		if err := os.Remove(paths[0]); err != nil {
			return err
		}
		paths = paths[1:]
	}
	return nil
}

func (q *Queue) listLocked() ([]string, error) {
	entries, err := os.ReadDir(q.dir)
	if err != nil {
		return nil, err
	}
	paths := make([]string, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() && strings.HasSuffix(entry.Name(), ".json") && !strings.HasPrefix(entry.Name(), ".pending-") {
			paths = append(paths, filepath.Join(q.dir, entry.Name()))
		}
	}
	sort.Strings(paths)
	return paths, nil
}
