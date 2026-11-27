package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"time"
)

const version = "0.1.0"

const breadcrumbLimit = 512

// Details deliberately have a fixed schema. No arbitrary strings, file paths,
// exception messages, window metadata or protocol payloads may enter a report.
type eventCode string

type breadcrumb struct {
	Sequence  uint64    `json:"sequence"`
	At        time.Time `json:"at"`
	ElapsedMS int64     `json:"elapsedMs"`
	Attempt   uint64    `json:"attempt,omitempty"`
	Event     eventCode `json:"event"`
	Value     *int      `json:"value,omitempty"`
}

type diagnosticReport struct {
	SchemaVersion    int          `json:"schemaVersion"`
	Version          string       `json:"version"`
	OS               string       `json:"os"`
	Architecture     string       `json:"architecture"`
	StartedAt        time.Time    `json:"startedAt"`
	ExportedAt       time.Time    `json:"exportedAt"`
	InputEnabled     bool         `json:"inputEnabled"`
	ClipboardEnabled bool         `json:"clipboardEnabled"`
	DiscoveryEnabled bool         `json:"discoveryEnabled"`
	Dropped          uint64       `json:"droppedBreadcrumbs"`
	Breadcrumbs      []breadcrumb `json:"breadcrumbs"`
}

type debugger struct {
	mu                          sync.Mutex
	start                       time.Time
	input, discovery, clipboard bool
	count                       uint64
	events                      [breadcrumbLimit]breadcrumb
}

func (d *debugger) add(attempt uint64, event eventCode, value ...int) {
	d.mu.Lock()
	defer d.mu.Unlock()
	now := time.Now()
	d.count++
	item := breadcrumb{Sequence: d.count, At: now.UTC(), ElapsedMS: now.Sub(d.start).Milliseconds(), Attempt: attempt, Event: event}
	if len(value) > 0 {
		item.Value = &value[0]
	}
	d.events[(d.count-1)%breadcrumbLimit] = item
}

func (d *debugger) snapshot() diagnosticReport {
	d.mu.Lock()
	defer d.mu.Unlock()
	count := min(d.count, breadcrumbLimit)
	dropped := d.count - count
	events := make([]breadcrumb, 0, count)
	for index := dropped; index < d.count; index++ {
		events = append(events, d.events[index%breadcrumbLimit])
	}
	return diagnosticReport{1, version, runtime.GOOS, runtime.GOARCH, d.start.UTC(),
		time.Now().UTC(), d.input, d.clipboard, d.discovery, dropped, events}
}

func (d *debugger) export(directory string) (string, error) {
	data, err := json.MarshalIndent(d.snapshot(), "", "  ")
	if err != nil {
		return "", err
	}
	name := filepath.Join(directory, "vamp-sync-linux-diagnostics-"+time.Now().UTC().Format("20060102T150405.000Z")+".json")
	file, err := os.OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return "", err
	}
	_, writeErr := file.Write(append(data, '\n'))
	if err := errors.Join(writeErr, file.Close()); err != nil {
		os.Remove(name)
		return "", err
	}
	return name, nil
}
