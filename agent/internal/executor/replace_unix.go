//go:build !windows

package executor

import "os"

func replaceFile(source, target string) error { return os.Rename(source, target) }
