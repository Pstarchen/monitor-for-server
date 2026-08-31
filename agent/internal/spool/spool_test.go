package spool

import (
	"os"
	"testing"
)

func TestQueueKeepsNewestReportsWithinLimit(t *testing.T) {
	queue, err := New(t.TempDir(), 2)
	if err != nil {
		t.Fatal(err)
	}
	for _, payload := range [][]byte{[]byte("one"), []byte("two"), []byte("three")} {
		if err := queue.Enqueue(payload); err != nil {
			t.Fatal(err)
		}
	}
	paths, err := queue.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(paths) != 2 {
		t.Fatalf("expected 2 reports, got %d", len(paths))
	}
	first, err := os.ReadFile(paths[0])
	if err != nil {
		t.Fatal(err)
	}
	if string(first) != "two" {
		t.Fatalf("expected oldest retained report to be two, got %q", first)
	}
}

func TestQueueDeliversNewestReportBeforeBufferedHistory(t *testing.T) {
	queue, err := New(t.TempDir(), 4)
	if err != nil {
		t.Fatal(err)
	}
	for _, payload := range [][]byte{[]byte("oldest"), []byte("older"), []byte("current")} {
		if err := queue.Enqueue(payload); err != nil {
			t.Fatal(err)
		}
	}
	paths, err := queue.ListForDelivery()
	if err != nil {
		t.Fatal(err)
	}
	if len(paths) != 3 {
		t.Fatalf("expected 3 reports, got %d", len(paths))
	}
	for index, expected := range []string{"current", "oldest", "older"} {
		payload, readErr := os.ReadFile(paths[index])
		if readErr != nil {
			t.Fatal(readErr)
		}
		if string(payload) != expected {
			t.Fatalf("expected report %d to be %q, got %q", index, expected, payload)
		}
	}
}
