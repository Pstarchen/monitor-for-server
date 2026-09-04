//go:build windows

package main

import (
	"errors"
	"os"
	"syscall"
	"unsafe"
)

const lockFileExclusiveLock = 0x00000002

var (
	kernel32LockFileEx   = syscall.NewLazyDLL("kernel32.dll").NewProc("LockFileEx")
	kernel32UnlockFileEx = syscall.NewLazyDLL("kernel32.dll").NewProc("UnlockFileEx")
)

type controllerUpdateStateFileLock struct {
	file       *os.File
	overlapped syscall.Overlapped
}

func acquireControllerUpdateStateFileLock(path string) (*controllerUpdateStateFileLock, error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	lock := &controllerUpdateStateFileLock{file: file}
	result, _, callErr := kernel32LockFileEx.Call(
		file.Fd(), lockFileExclusiveLock, 0, 1, 0, uintptr(unsafe.Pointer(&lock.overlapped)),
	)
	if result == 0 {
		file.Close()
		return nil, callErr
	}
	return lock, nil
}

func (lock *controllerUpdateStateFileLock) Close() error {
	result, _, callErr := kernel32UnlockFileEx.Call(
		lock.file.Fd(), 0, 1, 0, uintptr(unsafe.Pointer(&lock.overlapped)),
	)
	if result != 0 {
		callErr = nil
	}
	return errors.Join(callErr, lock.file.Close())
}
