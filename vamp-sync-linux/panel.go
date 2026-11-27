package main

import (
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"sync"
	"time"
)

// The companion and host communicate over the private child-process pipes.
// No listener, environment token, or privilege escalation is involved.
type panelOutput struct {
	sink io.Writer
	mu   sync.Mutex
}

func (p *panelOutput) emit(event fields) {
	if p == nil {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	json.NewEncoder(p.sink).Encode(event)
}

type panelDevice struct {
	Name        string `json:"name"`
	Fingerprint string `json:"fingerprint"`
}

func (h *host) snapshotForPanel() {
	if h.panel == nil {
		return
	}
	h.mu.Lock()
	pending, live := h.pending, h.live
	h.mu.Unlock()
	event := fields{
		"type": "status", "version": version,
		"address":  fmt.Sprintf("%s:%d", h.net.ip, plainPort),
		"hostName": h.id.peer.Name, "fingerprint": h.id.peer.Fingerprint,
		"desktopReady": h.desktop.active.Load(), "control": h.input,
		"devices": h.store.panelDevices(), "discovery": h.discovery.Load(),
	}
	if pending != nil && pending.ctx.Err() == nil && time.Now().Before(pending.deadline) {
		event["pending"] = panelDevice{Name: pending.peer.Name, Fingerprint: pending.peer.Fingerprint}
	}
	if live != nil {
		event["client"] = live.peer.Name
		if stream := live.panelStream.Load(); stream != nil {
			event["stream"] = *stream
			event["frames"] = live.panelFrames.Load()
		}
	}
	h.panel.emit(event)
}

func (h *host) reportToPanel(message string) {
	h.panel.emit(fields{"type": "error", "message": message})
}

func (s *state) panelDevices() []panelDevice {
	s.mu.Lock()
	defer s.mu.Unlock()
	devices := make([]panelDevice, 0, len(s.Trusted))
	for key := range s.Trusted {
		devices = append(devices, panelDevice{Name: s.Names[key], Fingerprint: key})
	}
	sort.Slice(devices, func(i, j int) bool {
		if devices[i].Name == devices[j].Name {
			return devices[i].Fingerprint < devices[j].Fingerprint
		}
		return devices[i].Name < devices[j].Name
	})
	return devices
}
