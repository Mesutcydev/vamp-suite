package main

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

const controlTag = 0
const videoTag = 1
const desktopID = "1"

type sessionOffer struct {
	SessionID          string
	SDP                string
	QualityPreset      string
	ClientCapabilities int
	ClientProductRole  string
	SealedSessionToken []byte
	SessionToken       *string
}

type descriptor struct {
	DataPort    int              `json:"dataPort,omitempty"`
	SessionID   string           `json:"sessionID"`
	Channels    []string         `json:"channels"`
	ChannelTags map[string]uint8 `json:"channelTags,omitempty"`
}

func validPreset(preset string) bool {
	switch preset {
	case "balanced", "performance", "quality", "ultra":
		return true
	}
	return false
}

func (o sessionOffer) valid() bool {
	var d descriptor
	return json.Unmarshal([]byte(o.SDP), &d) == nil && uuidPattern.MatchString(d.SessionID) && d.DataPort == 0 &&
		len(d.Channels) <= 16 && validPreset(o.QualityPreset) && o.ClientProductRole == "remoteControl" &&
		o.SessionToken == nil && len(o.SealedSessionToken) > 0 && o.ClientCapabilities&(1<<1) != 0
}

type application struct {
	Bundle  string            `json:"bundleIdentifier"`
	Name    string            `json:"name"`
	Running bool              `json:"isRunning"`
	Active  bool              `json:"isActive"`
	Windows []string          `json:"windowIDs"`
	Titles  map[string]string `json:"windowTitles,omitempty"`
	class   string
}

type target struct {
	Kind       string `json:"kind"`
	Identifier string `json:"identifier"`
}

type request struct {
	SessionID       string  `json:"sessionID"`
	SenderID        string  `json:"senderDeviceID"`
	RequestID       string  `json:"requestID,omitempty"`
	Offset          int     `json:"offset,omitempty"`
	Target          target  `json:"target"`
	TargetDisplayID string  `json:"targetDisplayID"`
	Bundle          string  `json:"bundleIdentifier"`
	SizingMode      string  `json:"sizingMode"`
	Aspect          float64 `json:"clientViewportAspect"`
	ViewportWidth   float64 `json:"viewportWidth"`
	ViewportHeight  float64 `json:"viewportHeight"`
	LaunchIfNeeded  bool    `json:"launchIfNeeded"`
}

type session struct {
	h       *host
	ctx     context.Context
	cancel  context.CancelFunc
	id      string
	peer    peer
	attempt uint64
	offer   sessionOffer
	token   []byte
	desktop bool

	conn                                       *net.TCPConn
	link                                       io.Writer
	authenticated                              bool
	inCounter, outCounter                      uint64
	videoSequence                              uint64
	capture                                    *capture
	window                                     uint32
	bounds                                     geometry
	preset                                     string
	input                                      inputState
	started                                    time.Time
	lastSwitch                                 time.Time
	inputAccepted, inputRejected, authRejected int
	lastList                                   []application
	lastRecovery                               time.Time
	lastInventory                              time.Time
	originalSizes                              map[uint32]geometry
	finished                                   chan struct{}
	resumeWindow                               uint32
	lastClipboard                              time.Time
	panelStream                                atomic.Pointer[string]
	panelFrames                                atomic.Uint64
}

func newSession(parent context.Context, h *host, offer sessionOffer, p peer, token []byte, attempt uint64) *session {
	ctx, cancel := context.WithCancel(parent)
	flags := offer.ClientCapabilities
	return &session{h: h, ctx: ctx, cancel: cancel, id: strings.ToUpper(offer.SessionID), peer: p, offer: offer,
		token: token, attempt: attempt, desktop: flags&(1<<16) != 0 && flags&(1<<4) != 0,
		preset: offer.QualityPreset, started: time.Now(), originalSizes: make(map[uint32]geometry), finished: make(chan struct{})}
}

func (s *session) mark(event eventCode, value ...int) { s.h.debug.add(s.attempt, event, value...) }

func (s *session) serve(ip net.IP, signal func(string, string, any) error) {
	listener, err := s.h.net.listen(dataPort)
	if err != nil {
		s.mark("data.bind_failed")
		return
	}
	defer listener.Close()
	stopListener := context.AfterFunc(s.ctx, func() { listener.Close() })
	defer stopListener()
	answer := descriptor{dataPort, uuid(), []string{"control", "video"}, map[string]uint8{"control": controlTag, "video": videoTag}}
	encoded, err := json.Marshal(answer)
	if err != nil {
		return
	}
	body := fields{"sessionID": s.id, "sdp": string(encoded)}
	ready := fields{"sessionID": s.id, "lockState": "unlockedActiveSession", "negotiatedCapabilities": fields{
		"videoCodec": "h264", "supportsMultiDisplay": s.desktop, "supportsAudio": false,
		"supportsMacClient": s.desktop, "supportsAppStreaming": s.offer.ClientCapabilities&(1<<14) != 0,
		"supportsCursorlessCapture": s.offer.ClientCapabilities&(1<<15) != 0,
	}}
	if s.desktop {
		body["acceptedDisplayID"], ready["selectedDisplayID"] = desktopID, desktopID
	}
	if signal(s.id, "answer", body) != nil || signal(s.id, "sessionReady", ready) != nil {
		s.mark("signal.answer_failed")
		return
	}
	s.mark("signal.answer_sent")
	deadline := time.Now().Add(10 * time.Second)
	for {
		conn, secure := s.acceptData(listener, ip, deadline)
		if secure == nil {
			s.mark("data.connection_failed")
			return
		}
		s.conn, s.link = conn, secure
		s.authenticated = false
		stopData := context.AfterFunc(s.ctx, func() { conn.Close() })
		s.mark("data.tls_ready")
		s.run(secure)
		stopData()
		conn.Close()
		secure.free()
		if s.ctx.Err() != nil || !s.h.desktop.active.Load() {
			return
		}
		s.mark("data.awaiting_reattach")
		deadline = time.Now().Add(5 * time.Second)
		// The sealed token and counter belong to the signaling session and
		// survive socket replacement. A retry must authenticate on the new TLS link.
	}
}

func (s *session) acceptData(listener *net.TCPListener, ip net.IP, deadline time.Time) (*net.TCPConn, *tlsSocket) {
	listener.SetDeadline(deadline)
	for range 8 {
		conn, err := listener.AcceptTCP()
		if err != nil {
			break
		}
		if !ip.Equal(conn.RemoteAddr().(*net.TCPAddr).IP) {
			conn.Close()
			continue
		}
		conn.SetDeadline(minTime(deadline, time.Now().Add(2*time.Second)))
		stop := context.AfterFunc(s.ctx, func() { conn.Close() })
		secure, err := s.h.tls.accept(conn, "vamp-data-channel-v1", s.token)
		stop()
		if err == nil {
			return conn, secure
		}
		conn.Close()
		s.mark("data.tls_failed")
	}
	return nil, nil
}

func minTime(a, b time.Time) time.Time {
	if a.Before(b) {
		return a
	}
	return b
}

func (s *session) run(reader io.Reader) {
	d, err := openDesktop()
	if err != nil {
		s.mark("capture.display_failed")
		s.cancel()
		return
	}
	defer d.close()
	s.input = inputState{d: d, keys: map[int][]int{}, keyRefs: map[int]int{}, buttons: map[int]bool{}}
	defer func() {
		s.endCapture()
		s.mark("input.accepted", s.inputAccepted)
		s.mark("input.rejected", s.inputRejected)
		s.mark("control.rejected", s.authRejected)
		s.mark("video.frames_sent", int(s.videoSequence))
		s.inputAccepted, s.inputRejected, s.authRejected = 0, 0, 0
	}()
	readCtx, cancelRead := context.WithCancel(s.ctx)
	requests := make(chan control, 16)
	readDone := make(chan struct{})
	go func() {
		defer close(readDone)
		defer close(requests)
		for {
			s.conn.SetReadDeadline(time.Now().Add(16 * time.Second))
			tag, data, err := packet(reader, true, wireLimit)
			if err != nil || tag != controlTag {
				return
			}
			var c control
			if json.Unmarshal(data, &c) != nil {
				return
			}
			select {
			case requests <- c:
			case <-readCtx.Done():
				return
			}
		}
	}()
	defer func() { cancelRead(); s.conn.Close(); <-readDone }()
	guardTick := time.NewTicker(200 * time.Millisecond)
	defer guardTick.Stop()
	authTimeout := time.NewTimer(10 * time.Second)
	defer authTimeout.Stop()
	if s.publishStatus() != nil {
		return
	}
	for {
		var frames <-chan encodedFrame
		if s.capture != nil {
			frames = s.capture.frames
		}
		select {
		case <-s.ctx.Done():
			return
		case <-guardTick.C:
			if !s.available() {
				s.mark("desktop.blocked")
				s.cancel()
				return
			}
		case <-authTimeout.C:
			if !s.authenticated {
				s.mark("control.timeout")
				return
			}
		case c, ok := <-requests:
			if !ok {
				s.mark("data.read_ended")
				return
			}
			if err := s.handle(c); err != nil {
				s.mark("data.command_failed")
				return
			}
		case frame, ok := <-frames:
			if !ok {
				window := s.window
				s.resumeWindow = 0
				s.endCapture()
				s.mark("capture.ended")
				if !s.available() || s.desktop {
					return
				}
				lost := request{SenderID: s.peer.ID, Target: target{"window", strconv.FormatUint(uint64(window), 10)}}
				if s.targetResult(lost, "failed", "Window closed, resized, or became unavailable.", wireTime()) != nil {
					return
				}
				continue
			}
			if !s.available() {
				s.cancel()
				return
			}
			if err := s.sendFrame(frame); err != nil {
				s.mark("video.write_failed")
				return
			}
		}
	}
}

func (s *session) available() bool {
	return s.ctx.Err() == nil && s.h.desktop.active.Load() && s.input.d.unlocked()
}

func (s *session) send(kind, sessionID string, payload any, auth bool) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	message := control{Kind: kind, SessionID: sessionID, Timestamp: wireTime(), Payload: data}
	if auth {
		s.outCounter++
		message.Counter = s.outCounter
		message.Nonce = make([]byte, 12)
		if _, err := rand.Read(message.Nonce); err != nil {
			return err
		}
		message.Tag = message.mac(s.token)
	}
	encoded, err := json.Marshal(message)
	if err != nil {
		return err
	}
	s.conn.SetWriteDeadline(time.Now().Add(3 * time.Second))
	return sendPacket(s.link, controlTag, encoded, true)
}

func (s *session) sendFrame(frame encodedFrame) error {
	s.conn.SetWriteDeadline(time.Now().Add(3 * time.Second))
	data := videoWire(frame, s.videoSequence+1, time.Since(s.started).Seconds(), s.capture.width, s.capture.height)
	if err := sendPacket(s.link, videoTag, data, true); err != nil {
		return err
	}
	s.videoSequence++
	s.panelFrames.Store(s.videoSequence)
	if s.videoSequence == 1 {
		s.mark("video.first_frame", len(data))
	}
	return nil
}

func (s *session) display() string {
	if s.window == 0 {
		return desktopID
	}
	return strconv.FormatUint(uint64(s.window), 10)
}

func displayLayout(id, name string, g geometry) fields {
	size := fields{"width": g.Width, "height": g.Height}
	rect := fields{"origin": fields{"x": 0, "y": 0}, "size": size}
	return fields{"primaryDisplayID": id, "virtualBounds": rect, "displays": []any{
		fields{"id": id, "name": name, "frame": rect, "pixelSize": size, "scaleFactor": 1, "rotation": 0, "isPrimary": true, "isActive": true},
	}}
}

func (s *session) publishStatus() error {
	mode := "viewOnly"
	if s.h.input {
		mode = "fullControl"
	}
	status := fields{"hostID": s.h.id.peer.ID, "connectionState": "connected", "activeSessionID": s.id,
		"sessionMode": mode, "supportsRemoteUnlock": false, "lockState": "unlockedActiveSession"}
	if s.desktop {
		g, err := s.input.d.bounds(0)
		if err != nil {
			return err
		}
		status["displayLayout"] = displayLayout(desktopID, "Linux Desktop", g)
		status["selectedDisplayID"] = desktopID
	}
	return s.send("hostStatus", s.id, status, false)
}

func (s *session) configureCapture(window uint32) (encodedFrame, error) {
	s.endCapture()
	if !s.available() {
		return encodedFrame{}, errX11
	}
	g, err := s.input.d.bounds(window)
	if err != nil {
		return encodedFrame{}, err
	}
	s.mark("capture.starting")
	c, err := startCapture(s.ctx, s.h.ffmpeg, window, g, s.preset, s.h.desktop.active.Load)
	if err != nil {
		s.mark("capture.start_failed")
		return encodedFrame{}, err
	}
	frame, err := c.first()
	if err != nil || !s.available() {
		c.stop()
		<-c.done
		s.mark("capture.first_frame_failed")
		return encodedFrame{}, errX11
	}
	s.capture, s.window, s.bounds = c, window, g
	s.resumeWindow = window
	title := "Linux Desktop"
	if window != 0 {
		title = s.input.d.windowTitle(window)
	}
	if title == "" {
		title = "App window"
	}
	s.panelStream.Store(&title)
	s.mark("capture.ready")
	return frame, nil
}

func (s *session) endCapture() {
	s.panelStream.Store(nil)
	s.input.release()
	if s.capture != nil {
		s.capture.stop()
		<-s.capture.done
		s.capture = nil
	}
}

func (s *session) desktopCapture() error {
	frame, err := s.configureCapture(0)
	if err != nil {
		return err
	}
	g := s.bounds
	layout := displayLayout(desktopID, "Linux Desktop", g)
	config := fields{"displayID": desktopID, "displayName": "Linux Desktop", "pixelWidth": g.Width, "pixelHeight": g.Height,
		"logicalWidth": g.Width, "logicalHeight": g.Height, "backingScaleFactor": 1, "originX": 0, "originY": 0,
		"rotation": 0, "isMain": true, "isActive": true, "streamWidth": s.capture.width, "streamHeight": s.capture.height,
		"captureRect": layout["virtualBounds"]}
	if err := s.send("displayConfigurationChanged", s.id, fields{"sessionID": s.id, "configuration": config, "layout": layout, "changedAt": wireTime()}, false); err != nil {
		return err
	}
	return s.sendFrame(frame)
}

func (s *session) handle(c control) error {
	if !c.fresh() {
		s.authRejected++
		return nil
	}
	switch c.Kind {
	case "ping":
		var p struct {
			ID     string
			SentAt *float64
		}
		if json.Unmarshal(c.Payload, &p) == nil && uuidPattern.MatchString(p.ID) && p.SentAt != nil {
			return s.send("pong", "", fields{"id": p.ID, "sentAt": p.SentAt, "receivedAt": wireTime()}, false)
		}
		return nil
	case "controlAuth":
		if s.authenticated {
			return nil
		}
		var p struct{ SessionID, SessionToken string }
		if json.Unmarshal(c.Payload, &p) != nil || !sameID(c.SessionID, s.id) || !sameID(p.SessionID, s.id) {
			s.authRejected++
			return nil
		}
		token, err := hex.DecodeString(p.SessionToken)
		if err != nil || !hmac.Equal(token, s.token) {
			s.authRejected++
			return nil
		}
		s.authenticated = true
		s.mark("control.authenticated")
		if s.desktop {
			return s.desktopCapture()
		}
		if s.resumeWindow != 0 {
			frame, err := s.configureCapture(s.resumeWindow)
			if err != nil {
				s.resumeWindow = 0
				return nil
			}
			s.mark("capture.reattached")
			return s.sendFrame(frame)
		}
		return nil
	}
	matchesSession := sameID(c.SessionID, s.id) || (c.Kind == "qualityAdjust" && c.SessionID == "")
	if !s.authenticated || !matchesSession || !c.valid(s.token, s.inCounter) {
		s.authRejected++
		return nil
	}
	s.inCounter = c.Counter
	if !s.available() {
		return errors.New("desktop unavailable")
	}
	switch c.Kind {
	case "inputCommand":
		if !s.h.input || s.capture == nil || s.input.inject(s.window, s.bounds, s.id, s.display(), c.Payload) != nil {
			s.inputRejected++
		} else {
			s.inputAccepted++
		}
	case "clipboardSync", "clipboardRequest":
		return s.clipboard(c)
	case "applicationList", "streamTargetSwitch", "applicationClose", "displaySwitch":
		var req request
		if json.Unmarshal(c.Payload, &req) != nil || !sameID(req.SessionID, s.id) || !sameID(req.SenderID, s.peer.ID) ||
			(req.RequestID != "" && !uuidPattern.MatchString(req.RequestID)) {
			return nil
		}
		switch c.Kind {
		case "applicationList":
			return s.list(req)
		case "streamTargetSwitch":
			return s.switchTarget(req)
		case "applicationClose":
			return s.closeApplication(req)
		case "displaySwitch":
			status := "rejected"
			if s.desktop && req.TargetDisplayID == desktopID {
				status = "completed"
				if s.capture == nil || s.window != 0 {
					if err := s.desktopCapture(); err != nil {
						return err
					}
				}
			}
			return s.send("displaySwitch", s.id, endpointResult(req, fields{
				"selectedDisplayID": s.display(), "status": status, "startedAt": wireTime(), "completedAt": wireTime(),
			}), true)
		}
	case "requestKeyframe":
		// The encoder emits an IDR with fresh headers once per second.
		var req request
		if json.Unmarshal(c.Payload, &req) == nil && sameID(req.SessionID, s.id) {
			s.markOncePerSecond("video.keyframe_requested")
		}
	case "qualityAdjust":
		// Existing clients recommend a preset but omit a nested session ID.
		var req struct{ RequestedPreset string }
		if json.Unmarshal(c.Payload, &req) != nil || !validPreset(req.RequestedPreset) || req.RequestedPreset == s.preset {
			return nil
		}
		if time.Since(s.lastSwitch) < time.Second {
			return nil
		}
		s.lastSwitch = time.Now()
		s.preset = req.RequestedPreset
		s.mark("video.quality_changed")
		if s.capture == nil {
			return nil
		}
		if s.desktop && s.window == 0 {
			return s.desktopCapture()
		}
		frame, err := s.configureCapture(s.window)
		if err != nil {
			return err
		}
		return s.sendFrame(frame)
	}
	return nil
}

func (s *session) markOncePerSecond(code eventCode) {
	// Recovery requests can arrive in bursts. Reuse the normal diagnostic
	// sample cadence without allowing repeated requests to evict setup events.
	if time.Since(s.lastRecovery) >= time.Second {
		s.lastRecovery = time.Now()
		s.mark(code)
	}
}

func endpointResult(req request, values fields) fields {
	values["sessionID"], values["senderDeviceID"] = req.SessionID, req.SenderID
	if req.RequestID != "" {
		values["requestID"] = req.RequestID
	}
	return values
}

func (s *session) list(req request) error {
	if req.Offset < 0 || req.Offset > 576 {
		return nil
	}
	if req.Offset == 0 && s.resumeWindow != 0 {
		s.resumeWindow = 0
		s.endCapture()
		s.mark("capture.returned_to_browser")
	}
	if req.Offset == 0 && (s.lastList == nil || time.Since(s.lastInventory) > 500*time.Millisecond) {
		s.lastInventory = time.Now()
		list, err := s.inventory()
		if err != nil {
			s.mark("inventory.failed")
			list = []application{}
		}
		s.lastList = list
		s.mark("inventory.ready", len(list))
	}
	if req.Offset > len(s.lastList) {
		return nil
	}
	end := min(req.Offset+40, len(s.lastList))
	items := append([]application{}, s.lastList[req.Offset:end]...)
	result := endpointResult(req, fields{"offset": req.Offset, "applications": items, "capturedAt": wireTime()})
	if end < len(s.lastList) {
		result["nextOffset"] = end
	}
	return s.send("applicationList", s.id, result, true)
}

func (s *session) switchTarget(req request) error {
	start := wireTime()
	if time.Since(s.lastSwitch) < 500*time.Millisecond {
		return s.targetResult(req, "rejected", "Wait for the current window switch to finish.", start)
	}
	s.lastSwitch = time.Now()
	if req.Target.Kind == "display" && s.desktop && req.Target.Identifier == desktopID {
		return s.desktopCapture()
	}
	windowID, err := s.windowFor(req.Target)
	if err != nil {
		return s.targetResult(req, "failed", "Could not enumerate X11 windows.", start)
	}
	if windowID == 0 && req.LaunchIfNeeded {
		windowID, err = s.launch(req.Target)
		if err != nil {
			s.mark("capture.launch_failed")
			return s.targetResult(req, "failed", "The application did not open an X11 window.", start)
		}
	}
	if windowID == 0 {
		s.mark("capture.target_rejected")
		return s.targetResult(req, "rejected", "Select an open X11 window or an app enabled for launch.", start)
	}
	window := strconv.FormatUint(uint64(windowID), 10)

	if s.h.input {
		s.endCapture()
		s.input.d.activate(windowID)
		req.SizingMode = s.resizeWindow(req, windowID)
	}
	frame, err := s.configureCapture(windowID)
	req.Target = target{"window", window}
	if err != nil {
		return s.targetResult(req, "failed", "The X11 window could not be captured.", start)
	}
	if err := s.targetResult(req, "completed", "", start); err != nil {
		return err
	}
	return s.sendFrame(frame)
}

func (s *session) targetResult(req request, status, reason string, start float64) error {
	if req.SessionID == "" {
		req.SessionID = s.id
	}
	result := endpointResult(req, fields{"resolvedTarget": req.Target, "status": status, "startedAt": start, "completedAt": wireTime()})
	if reason != "" {
		result["reason"] = reason
	}
	if status == "completed" {
		result["width"], result["height"], result["scaleFactor"] = s.bounds.Width, s.bounds.Height, 1
		if s.h.input && req.SizingMode != "" {
			result["appliedSizingMode"] = req.SizingMode
		}
	}
	return s.send("streamTargetSwitch", s.id, result, true)
}

func (s *session) resizeWindow(req request, id uint32) string {
	d := s.input.d
	current, err := d.bounds(id)
	if err != nil {
		return ""
	}
	original, exists := s.originalSizes[id]
	if !exists {
		if len(s.originalSizes) >= 128 {
			clear(s.originalSizes)
		}
		original = current
		s.originalSizes[id] = original
	}
	mode := "original"
	w, h := original.Width, original.Height
	if req.SizingMode == "adaptive" {
		aspect := req.Aspect
		if req.ViewportWidth > 0 && req.ViewportHeight > 0 {
			aspect = req.ViewportWidth / req.ViewportHeight
		}
		if aspect < 0.25 || aspect > 4 {
			return mode
		}
		root, err := d.bounds(0)
		if err != nil {
			return mode
		}
		area := float64(w * h)
		w = min(root.Width-40, max(160, int(math.Sqrt(area*aspect))))
		h = min(root.Height-80, max(120, int(float64(w)/aspect)))
		w = min(root.Width-40, max(160, int(float64(h)*aspect)))
		mode = "adaptive"
	}
	if (w != current.Width || h != current.Height) && w > 0 && h > 0 && d.resize(id, w, h) {
		until := time.Now().Add(400 * time.Millisecond)
		for time.Now().Before(until) && s.available() {
			time.Sleep(25 * time.Millisecond)
			updated, err := d.bounds(id)
			if err != nil || (updated.Width != current.Width || updated.Height != current.Height) {
				break
			}
		}
		s.mark("capture.resize_requested")
	}
	return mode
}

func (s *session) closeApplication(req request) error {
	result := fields{"bundleIdentifier": req.Bundle, "status": "rejected",
		"reason": "The window could not be closed remotely.", "completedAt": wireTime()}
	if s.h.input && time.Since(s.lastSwitch) >= 500*time.Millisecond {
		s.lastSwitch = time.Now()
		list, err := s.inventory()
		if err == nil {
			for _, app := range list {
				if app.Bundle != req.Bundle || len(app.Windows) == 0 {
					continue
				}
				id, err := strconv.ParseUint(app.Windows[0], 10, 32)
				if err == nil && id != 0 && s.input.d.requestClose(uint32(id)) {
					if s.window == uint32(id) {
						s.resumeWindow = 0
						s.endCapture()
					}
					delete(result, "reason")
					result["status"] = "completed"
					s.mark("capture.close_requested")
				}
				break
			}
		}
	}
	return s.send("applicationClose", s.id, endpointResult(req, result), true)
}
