//go:build linux

package main

import (
	"errors"
	"os"
	"syscall"
)

type controllerUpdateStateFileLock struct {
	file *os.File
}

func acquireControllerUpdateStateFileLock(path string) (*controllerUpdateStateFileLock, error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	for {
		err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX)
		if !errors.Is(err, syscall.EINTR) {
			break
		}
	}
	if err != nil {
		file.Close()
		return nil, err
	}
	return &controllerUpdateStateFileLock{file: file}, nil
}

func (lock *controllerUpdateStateFileLock) Close() error {
	unlockErr := syscall.Flock(int(lock.file.Fd()), syscall.LOCK_UN)
	return errors.Join(unlockErr, lock.file.Close())
}
