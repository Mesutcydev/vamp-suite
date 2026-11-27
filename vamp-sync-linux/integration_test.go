package main

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

type testPSK struct {
	in   io.WriteCloser
	out  io.ReadCloser
	stop func()
}

func pskClient(t *testing.T, address, identity string, key []byte) testPSK {
	t.Helper()
	if tool := os.Getenv("VAMP_TEST_PSK_CLIENT"); tool != "" {
		return startTestClient(t, tool, address, identity, hex.EncodeToString(key))
	}
	openssl, err := exec.LookPath("openssl")
	if err != nil {
		t.Skip("OpenSSL CLI unavailable")
	}
	return startTestClient(t, openssl, "s_client", "-quiet", "-tls1_2", "-cipher", "PSK-AES256-GCM-SHA384",
		"-psk_identity", identity, "-psk", hex.EncodeToString(key), "-connect", address)
}

func startTestClient(t *testing.T, binary string, args ...string) testPSK {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	t.Cleanup(cancel)
	cmd := exec.CommandContext(ctx, binary, args...)
	in, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	stop := sync.OnceFunc(func() { cancel(); in.Close(); cmd.Wait() })
	t.Cleanup(stop)
	return testPSK{in, out, stop}
}

func (p testPSK) Read(b []byte) (int, error)  { return p.out.Read(b) }
func (p testPSK) Write(b []byte) (int, error) { return p.in.Write(b) }

func testListen(t *testing.T) *net.TCPListener {
	t.Helper()
	ln, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	ln.SetDeadline(time.Now().Add(12 * time.Second))
	return ln
}

func TestTLSPSK(t *testing.T) {
	c, err := newTLSContext()
	if err != nil {
		t.Fatal(err)
	}
	defer c.close()
	key := make([]byte, 32)
	rand.Read(key)
	for _, mode := range []string{"psk", "certificate_only"} {
		t.Run(mode, func(t *testing.T) {
			ln := testListen(t)
			if mode == "psk" {
				peer := pskClient(t, ln.Addr().String(), "vamp-data-channel-v1", key)
				if err := sendPacket(peer, 3, []byte("hello"), true); err != nil {
					t.Fatal(err)
				}
				conn, err := ln.AcceptTCP()
				if err != nil {
					t.Fatal(err)
				}
				defer conn.Close()
				conn.SetDeadline(time.Now().Add(4 * time.Second))
				secure, err := c.accept(conn, "vamp-data-channel-v1", key)
				if err != nil {
					t.Fatal(err)
				}
				defer secure.free()
				tag, msg, err := packet(secure, true, 40)
				if err != nil || tag != 3 || string(msg) != "hello" {
					t.Fatalf("PSK read: %d %q %v", tag, msg, err)
				}
				if err := sendPacket(secure, 4, msg, true); err != nil {
					t.Fatal(err)
				}
				if tag, _, err := packet(peer, true, 40); err != nil || tag != 4 {
					t.Fatalf("PSK response: %v", err)
				}
				return
			}
			done := make(chan struct{})
			go func() {
				defer close(done)
				client, err := tls.DialWithDialer(&net.Dialer{Timeout: 2 * time.Second}, "tcp4", ln.Addr().String(),
					&tls.Config{InsecureSkipVerify: true, MinVersion: tls.VersionTLS13})
				if err == nil {
					client.Close()
				}
			}()
			conn, err := ln.AcceptTCP()
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			conn.SetDeadline(time.Now().Add(4 * time.Second))
			if socket, err := c.accept(conn, "vamp-data-channel-v1", key); err == nil {
				socket.free()
				t.Fatal("accepted unbound certificate TLS")
			}
			<-done
		})
	}
}

func sealForTest(t *testing.T, key *ecdh.PublicKey, token []byte) []byte {
	t.Helper()
	ephemeral, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	shared, err := ephemeral.ECDH(key)
	if err != nil {
		t.Fatal(err)
	}
	sym, err := hkdf.Key(sha256.New, shared, []byte(sealingSalt), sealingInfo, 32)
	if err != nil {
		t.Fatal(err)
	}
	block, err := aes.NewCipher(sym)
	if err != nil {
		t.Fatal(err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	nonce := make([]byte, gcm.NonceSize())
	rand.Read(nonce)
	box := append(append([]byte{1}, ephemeral.PublicKey().Bytes()...), nonce...)
	return gcm.Seal(box, nonce, token, nil)
}

func TestX11HostFlow(t *testing.T) {
	if os.Getenv("VAMP_TEST_X11") != "1" {
		t.Skip("requires a disposable EWMH X11 desktop and FFmpeg")
	}
	inputFile := filepath.Join(t.TempDir(), "received")
	terminal := exec.Command("xterm", "-T", "Vamp test window", "-e", "sh", "-c", `printf 'Ready\n'; IFS= read -r line && printf '%s' "$line" > "$1"; sleep 20`, "test", inputFile)
	if err := terminal.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { terminal.Process.Kill(); terminal.Wait() })
	d, err := openDesktop()
	if err != nil {
		t.Fatal(err)
	}
	defer d.close()
	if !d.unlocked() || !d.inputAvailable() {
		t.Fatal("required X11 extensions unavailable")
	}
	var app application
	until := time.Now().Add(3 * time.Second)
	for time.Now().Before(until) {
		apps, _ := d.windows()
		for _, a := range apps {
			if a.Name == "Vamp test window" {
				app = a
				break
			}
		}
		if app.Bundle != "" {
			break
		}
		time.Sleep(40 * time.Millisecond)
	}
	if app.Bundle == "" {
		t.Fatal("xterm not visible in X11 inventory")
	}
	hostStore, err := loadState(filepath.Join(t.TempDir(), "host"))
	if err != nil {
		t.Fatal(err)
	}
	clientStore, err := loadState(filepath.Join(t.TempDir(), "client"))
	if err != nil {
		t.Fatal(err)
	}
	hostID, err := hostStore.identity("Test Linux")
	if err != nil {
		t.Fatal(err)
	}
	client, err := clientStore.identity("Test iOS")
	if err != nil {
		t.Fatal(err)
	}
	client.peer.Role = "client"
	tlsLayer, err := newTLSContext()
	if err != nil {
		t.Fatal(err)
	}
	defer tlsLayer.close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	n, err := scopeFor("127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	host := host{ctx: ctx, cancel: cancel, id: hostID, store: hostStore, tls: tlsLayer, net: n, desktop: &desktopGuard{},
		debug: &debugger{start: time.Now(), input: true}, input: true, ffmpeg: "ffmpeg", replay: replayCache{ids: map[string]time.Time{}}}
	var panel bytes.Buffer
	host.panel = &panelOutput{sink: &panel}
	host.desktop.active.Store(true) // The disposable Xvfb has no logind seat.
	host.clipboard, err = exec.LookPath("xclip")
	if err != nil {
		t.Fatal(err)
	}
	ln := testListen(t)
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		if c, err := ln.AcceptTCP(); err == nil {
			host.signaling(c, false, nil)
		}
	}()
	defer func() { cancel(); ln.Close(); <-finished }()
	signaling, err := net.Dial("tcp4", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer signaling.Close()
	signaling.SetDeadline(time.Now().Add(15 * time.Second))
	sessionID := uuid()
	sign := func(kind string, body fields) {
		t.Helper()
		raw, err := client.signed(sessionID, kind, body)
		if err != nil {
			t.Fatal(err)
		}
		if err := sendPacket(signaling, 0, raw, false); err != nil {
			t.Fatal(err)
		}
	}
	signal := func(kind string) json.RawMessage {
		t.Helper()
		_, raw, err := packet(signaling, false, 16<<10)
		if err != nil {
			t.Fatal(err)
		}
		var m signalMessage
		if err := json.Unmarshal(raw, &m); err != nil || m.Envelope.Event[kind] == nil || m.Envelope.Sender.Fingerprint != hostID.peer.Fingerprint {
			t.Fatalf("expected %s, got %v: %v", kind, m.Envelope.Event, err)
		}
		return m.Envelope.Event[kind]["_0"]
	}
	sign("hostKeyRequest", fields{"nonce": make([]byte, 32)})
	signal("hostKeyBundle")
	token := make([]byte, 32)
	rand.Read(token)
	sdp, _ := json.Marshal(descriptor{SessionID: uuid(), Channels: []string{}})
	sign("offer", fields{"sessionID": sessionID, "sdp": string(sdp), "qualityPreset": "performance",
		"sealedSessionToken": sealForTest(t, hostID.agreement.PublicKey(), token), "clientCapabilities": 1<<14 | 1<<1,
		"clientProductRole": "remoteControl"})
	promptDeadline := time.Now().Add(2 * time.Second)
	for {
		host.panel.mu.Lock()
		pending := strings.Contains(panel.String(), `"pending":{"name":"Test iOS"`)
		host.panel.mu.Unlock()
		if pending {
			break
		}
		if time.Now().After(promptDeadline) {
			t.Fatal("no verified pairing request")
		}
		time.Sleep(15 * time.Millisecond)
	}
	console, consoleWriter := io.Pipe()
	defer consoleWriter.Close()
	go host.console(console)
	fmt.Fprintln(consoleWriter, "approve", client.peer.Fingerprint) // Exact fingerprint of the synthetic test client.
	signal("answer")
	signal("sessionReady")

	link := pskClient(t, net.JoinHostPort("127.0.0.1", strconv.Itoa(dataPort)), "vamp-data-channel-v1", token)
	var count uint64
	send := func(kind string, body fields, authenticated bool) {
		t.Helper()
		encoded, _ := json.Marshal(body)
		c := control{Kind: kind, SessionID: sessionID, Timestamp: wireTime(), Payload: encoded}
		if authenticated {
			count++
			c.Counter, c.Nonce = count, make([]byte, 12)
			c.Tag = c.mac(token)
		}
		data, _ := json.Marshal(c)
		if err := sendPacket(link, controlTag, data, true); err != nil {
			t.Fatal(err)
		}
	}
	recv := func(kind string) control {
		t.Helper()
		for range 100 {
			tag, data, err := packet(link, true, wireLimit)
			if err != nil {
				t.Fatal(err)
			}
			if tag == videoTag {
				continue
			}
			var c control
			if err := json.Unmarshal(data, &c); err != nil {
				t.Fatal(err)
			}
			if c.Kind == kind {
				return c
			}
		}
		t.Fatalf("no %s", kind)
		return control{}
	}
	send("controlAuth", fields{"sessionID": sessionID, "sessionToken": hex.EncodeToString(token)}, false)
	send("applicationList", fields{"sessionID": sessionID, "senderDeviceID": client.peer.ID, "offset": 0}, true)
	list := recv("applicationList")
	if !list.valid(token, 0) || !strings.Contains(string(list.Payload), app.Bundle) {
		t.Fatal("application list absent or unauthenticated")
	}
	send("streamTargetSwitch", fields{"sessionID": sessionID, "senderDeviceID": client.peer.ID, "requestID": uuid(),
		"target": target{"application", app.Bundle}}, true)
	selected := recv("streamTargetSwitch")
	if !selected.valid(token, list.Counter) || !strings.Contains(string(selected.Payload), `"status":"completed"`) {
		t.Fatalf("target failed: %s", selected.Payload)
	}
	tag, video, err := packet(link, true, wireLimit)
	if err != nil || tag != videoTag || len(video) < 34 || string(video[:2]) != "VF" || video[4] != 1 {
		t.Fatalf("first video packet: tag=%d length=%d err=%v", tag, len(video), err)
	}
	send("inputCommand", fields{"sessionID": sessionID, "command": fields{
		"pointerButton": fields{"_0": fields{"button": "left", "action": "click", "location": fields{"x": 100, "y": 80}, "displayID": app.Windows[0]}},
	}}, true)
	send("inputCommand", fields{"sessionID": sessionID, "command": fields{
		"text": fields{"_0": fields{"text": "test42\n"}},
	}}, true)
	until = time.Now().Add(3 * time.Second)
	for time.Now().Before(until) {
		if contents, _ := os.ReadFile(inputFile); string(contents) == "test42" {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if contents, _ := os.ReadFile(inputFile); string(contents) != "test42" {
		t.Fatal("authorized XTEST input did not reach the selected window")
	}
	host.snapshotForPanel()
	host.panel.mu.Lock()
	events := panel.String()
	host.panel.mu.Unlock()
	if !strings.Contains(events, `"pending":{"name":"Test iOS"`) ||
		!strings.Contains(events, `"stream":"Vamp test window"`) ||
		!strings.Contains(events, `"devices":[{"name":"Test iOS"`) {
		t.Fatal("missing live or pairing state for GTK companion")
	}

	firstLink := link
	firstLink.stop()
	link = pskClient(t, net.JoinHostPort("127.0.0.1", strconv.Itoa(dataPort)), "vamp-data-channel-v1", token)
	send("controlAuth", fields{"sessionID": sessionID, "sessionToken": hex.EncodeToString(token)}, false)
	recv("hostStatus")
	tag, video, err = packet(link, true, wireLimit)
	if err != nil || tag != videoTag || len(video) < 34 || video[4] != 1 {
		t.Fatalf("reattached video: tag=%d length=%d err=%v", tag, len(video), err)
	}

	send("clipboardSync", fields{"sessionID": sessionID, "source": "client", "text": "Vamp clipboard ✓"}, true)
	time.Sleep(550 * time.Millisecond)
	send("clipboardRequest", fields{"sessionID": sessionID}, true)
	clip := recv("clipboardSync")
	if !clip.valid(token, selected.Counter) || !strings.Contains(string(clip.Payload), "Vamp clipboard ✓") {
		t.Fatal("clipboard round trip failed")
	}

	send("applicationClose", fields{"sessionID": sessionID, "senderDeviceID": client.peer.ID, "requestID": uuid(), "bundleIdentifier": app.Bundle}, true)
	if closed := recv("applicationClose"); !strings.Contains(string(closed.Payload), `"status":"completed"`) {
		t.Fatalf("close failed: %s", closed.Payload)
	}
	fmt.Fprintln(consoleWriter, "disconnect")
	<-finished
	report := host.debug.snapshot()
	for _, want := range []eventCode{"pair.approved", "capture.ready", "capture.reattached", "clipboard.sent", "session.closed"} {
		found := false
		for _, event := range report.Breadcrumbs {
			if event.Event == want {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("missing diagnostic event %s", want)
		}
	}
}

func TestX11DesktopFrames(t *testing.T) {
	if os.Getenv("VAMP_TEST_X11") != "1" {
		t.Skip("requires a disposable X11 desktop and FFmpeg")
	}
	d, err := openDesktop()
	if err != nil {
		t.Fatal(err)
	}
	defer d.close()
	g, err := d.bounds(0)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	c, err := startCapture(ctx, "ffmpeg", 0, g, "performance", func() bool { return true })
	if err != nil {
		t.Fatal(err)
	}
	defer func() { c.stop(); <-c.done }()
	frame, err := c.first()
	if err != nil {
		t.Fatal(err)
	}
	if !frame.key || len(frame.parameters) == 0 || len(frame.sample) == 0 {
		t.Fatal("invalid initial desktop frame")
	}
}
