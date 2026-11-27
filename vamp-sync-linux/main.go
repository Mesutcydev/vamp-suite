package main

import (
	"bufio"
	"context"
	"crypto/hkdf"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const plainPort = 9471
const dataPort = 9472
const securePort = 9473

var localDisplay = regexp.MustCompile(`^:[0-9]+(\.[0-9]+)?$`)
var sessionName = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,64}$`)
var fingerprintPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)

type networkScope struct {
	ip      net.IP
	subnet  *net.IPNet
	tailnet bool
}

var tailnetRange = &net.IPNet{IP: net.IPv4(100, 64, 0, 0).To4(), Mask: net.CIDRMask(10, 32)}

func scopeFor(value string) (networkScope, error) {
	ip := net.ParseIP(value).To4()
	if ip == nil || (!ip.IsPrivate() && !ip.IsLoopback() && !tailnetRange.Contains(ip)) {
		return networkScope{}, errors.New("bind must be a local private IPv4 address")
	}
	interfaces, err := net.Interfaces()
	if err != nil {
		return networkScope{}, err
	}
	for _, nic := range interfaces {
		addresses, err := nic.Addrs()
		if err != nil {
			continue
		}
		for _, address := range addresses {
			a, ok := address.(*net.IPNet)
			if !ok || !a.IP.Equal(ip) {
				continue
			}
			tailnet := tailnetRange.Contains(ip)
			if tailnet && nic.Name != "tailscale0" {
				continue
			}
			return networkScope{ip, a, tailnet}, nil
		}
	}
	return networkScope{}, errors.New("bind address is not assigned to an eligible interface")
}

func (n networkScope) allows(ip net.IP) bool {
	switch {
	case n.tailnet:
		return tailnetRange.Contains(ip)
	case n.ip.IsLoopback():
		return ip.IsLoopback()
	default:
		return ip.IsPrivate() && n.subnet.Contains(ip)
	}
}

func (n networkScope) listen(port int) (*net.TCPListener, error) {
	return net.ListenTCP("tcp4", &net.TCPAddr{IP: n.ip, Port: port})
}

type desktopGuard struct {
	id, display, loginctl string
	active                atomic.Bool
}

func (g *desktopGuard) check(parent context.Context) bool {
	ctx, cancel := context.WithTimeout(parent, 450*time.Millisecond)
	defer cancel()
	output, err := exec.CommandContext(ctx, g.loginctl, "show-session", g.id,
		"-p", "Active", "-p", "LockedHint", "-p", "Remote", "-p", "Type", "-p", "User", "-p", "Display").Output()
	if err != nil {
		return false
	}
	props := map[string]string{}
	for _, line := range strings.Split(string(output), "\n") {
		key, value, ok := strings.Cut(line, "=")
		if ok {
			props[key] = value
		}
	}
	return props["Active"] == "yes" && props["LockedHint"] == "no" && props["Remote"] == "no" &&
		props["Type"] == "x11" && props["User"] == strconv.Itoa(os.Getuid()) &&
		(props["Display"] == "" || strings.TrimSuffix(props["Display"], ".0") == strings.TrimSuffix(g.display, ".0"))
}

type pendingPair struct {
	peer     peer
	attempt  uint64
	result   chan bool
	ctx      context.Context
	deadline time.Time
}

type host struct {
	ctx       context.Context
	cancel    context.CancelFunc
	id        identity
	store     *state
	debug     *debugger
	tls       *tlsContext
	replay    replayCache
	net       networkScope
	desktop   *desktopGuard
	ffmpeg    string
	input     bool
	mu        sync.Mutex
	pending   *pendingPair
	live      *session
	attempt   atomic.Uint64
	apps      launchApps
	launcher  string
	clipboard string
	panel     *panelOutput
	discovery atomic.Bool
}

func (h *host) pair(ctx context.Context, p peer, attempt uint64) bool {
	if h.store.isTrusted(p) {
		h.debug.add(attempt, "pair.trusted")
		return true
	}
	prompt := &pendingPair{p, attempt, make(chan bool, 1), ctx, time.Now().Add(55 * time.Second)}
	h.mu.Lock()
	if h.pending != nil || h.live != nil {
		h.mu.Unlock()
		return false
	}
	h.pending = prompt
	h.mu.Unlock()
	defer func() {
		h.mu.Lock()
		if h.pending == prompt {
			h.pending = nil
		}
		h.mu.Unlock()
	}()
	h.debug.add(attempt, "pair.pending")
	h.snapshotForPanel()
	// %q escapes terminal control sequences supplied as a device display name.
	fmt.Fprintf(h.logWriter(), "\nPairing request from %.120q\nFingerprint: %s\nAfter verifying it on the client, type approve <fingerprint>. To decline, type deny.\n", p.Name, p.Fingerprint)
	timer := time.NewTimer(time.Until(prompt.deadline))
	defer timer.Stop()
	select {
	case allowed := <-prompt.result:
		return allowed
	case <-timer.C:
		h.debug.add(attempt, "pair.expired")
	case <-ctx.Done():
		h.debug.add(attempt, "pair.abandoned")
	}
	return false
}

func (h *host) console(reader io.Reader) {
	s := bufio.NewScanner(reader)
	s.Buffer(make([]byte, 1024), 4096)
	for s.Scan() {
		parts := strings.Fields(s.Text())
		if len(parts) == 0 {
			continue
		}
		switch parts[0] {
		case "approve", "deny":
			h.mu.Lock()
			p := h.pending
			if p == nil || p.ctx.Err() != nil || time.Now().After(p.deadline) {
				fmt.Fprintln(h.logWriter(), "No pending pairing.")
			} else if parts[0] == "approve" && (len(parts) != 2 || parts[1] != p.peer.Fingerprint) {
				h.debug.add(p.attempt, "pair.fingerprint_mismatch")
				fmt.Fprintln(h.logWriter(), "Fingerprint mismatch.")
			} else if parts[0] == "deny" && len(parts) > 1 && (len(parts) != 2 || parts[1] != p.peer.Fingerprint) {
				fmt.Fprintln(h.logWriter(), "No matching pending pairing.")
			} else {
				approved := parts[0] == "approve"
				if approved && h.store.trust(p.peer) != nil {
					h.debug.add(p.attempt, "pair.storage_failed")
					fmt.Fprintln(h.logWriter(), "Could not save pairing.")
					h.reportToPanel("Could not save pairing.")
				} else {
					h.pending = nil
					event := eventCode("pair.denied")
					if approved {
						event = "pair.approved"
					}
					h.debug.add(p.attempt, event)
					p.result <- approved
				}
			}
			h.mu.Unlock()
		case "diagnose":
			h.debug.add(0, "diagnostics.export_requested")
			path, err := h.debug.export(h.store.dir)
			if err != nil {
				fmt.Fprintln(h.logWriter(), "Diagnostic export failed.")
				h.reportToPanel("Diagnostic export failed.")
				continue
			}
			fmt.Fprintln(h.logWriter(), "Diagnostic report:", path)
			h.panel.emit(fields{"type": "report", "path": path})
		case "status":
			h.mu.Lock()
			fmt.Fprintf(h.logWriter(), "Desktop available: %t, pending pairing: %t, active connection: %t\n", h.desktop.active.Load(), h.pending != nil, h.live != nil)
			h.mu.Unlock()
		case "disconnect":
			h.mu.Lock()
			if h.live != nil {
				h.live.cancel()
			}
			h.mu.Unlock()
		case "revoke":
			if len(parts) != 2 || !fingerprintPattern.MatchString(parts[1]) {
				fmt.Fprintln(h.logWriter(), "Use revoke <fingerprint>.")
				continue
			}
			h.mu.Lock()
			err := h.store.revoke(parts[1])
			if err == nil && h.live != nil && h.live.peer.Fingerprint == parts[1] {
				h.live.cancel()
			}
			h.mu.Unlock()
			if err != nil {
				fmt.Fprintln(h.logWriter(), "Revocation failed.")
				h.reportToPanel("Revocation failed.")
				continue
			}
			h.debug.add(0, "pair.revoked")
			fmt.Fprintln(h.logWriter(), "Revoked.")
		case "quit":
			h.cancel()
			return
		default:
			fmt.Fprintln(h.logWriter(), "Commands: status, approve <fingerprint>, deny, disconnect, revoke <fingerprint>, diagnose, quit")
		}
		h.snapshotForPanel()
	}
	// Pairing authority belongs to the local console.
	h.cancel()
}

func (h *host) logWriter() io.Writer {
	if h.panel != nil {
		return os.Stderr
	}
	return os.Stdout
}

func (h *host) signaling(conn *net.TCPConn, isTLS bool, psk []byte) {
	defer conn.Close()
	attempt := h.attempt.Add(1)
	h.debug.add(attempt, "signal.accepted")
	ctx, cancel := context.WithCancel(h.ctx)
	defer cancel()
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	link := io.ReadWriter(conn)
	if isTLS {
		secure, err := h.tls.accept(conn, "remotedesktop", psk)
		if err != nil {
			h.debug.add(attempt, "signal.tls_failed")
			return
		}
		defer secure.free()
		link = secure
		h.debug.add(attempt, "signal.tls_ready")
	}
	read := func() (signalEnvelope, error) {
		_, data, err := packet(link, false, 16<<10)
		if err != nil {
			return signalEnvelope{}, err
		}
		return h.replay.verify(data, h.id.peer)
	}
	send := func(id, kind string, payload any) error {
		data, err := h.id.signed(id, kind, payload)
		if err != nil {
			return err
		}
		conn.SetWriteDeadline(time.Now().Add(4 * time.Second))
		return sendPacket(link, 0, data, false)
	}
	first, err := read()
	if err != nil {
		h.debug.add(attempt, "signal.invalid")
		return
	}
	var req struct{ Nonce []byte }
	if eventBody(first, "hostKeyRequest", &req) != nil {
		h.debug.add(attempt, "signal.invalid")
		return
	}
	bundle, err := h.id.bundle(req.Nonce)
	if err != nil || send(first.SessionID, "hostKeyBundle", bundle) != nil {
		h.debug.add(attempt, "signal.key_failed")
		return
	}
	h.debug.add(attempt, "signal.key_sent")
	conn.SetReadDeadline(time.Now().Add(115 * time.Second)) // Client may have to approve the host.
	second, err := read()
	if err != nil || !sameID(first.SessionID, second.SessionID) || !sameID(first.Sender.ID, second.Sender.ID) ||
		first.Sender.Fingerprint != second.Sender.Fingerprint {
		h.debug.add(attempt, "signal.offer_invalid")
		return
	}
	var offer sessionOffer
	if eventBody(second, "offer", &offer) != nil || !sameID(offer.SessionID, second.SessionID) || !offer.valid() {
		h.debug.add(attempt, "signal.offer_invalid")
		return
	}
	token, err := h.id.unseal(offer.SealedSessionToken)
	if err != nil {
		h.debug.add(attempt, "signal.token_rejected")
		return
	}
	h.debug.add(attempt, "signal.offer_verified")
	// A read watcher observes an abandoned client before its pending approval can
	// resolve. No more signaling requests are valid after the signed offer.
	conn.SetReadDeadline(time.Time{})
	watchDone := make(chan struct{})
	go func() {
		defer close(watchDone)
		var extra [1]byte
		link.Read(extra[:])
		cancel()
	}()
	defer func() { conn.Close(); <-watchDone }()
	h.mu.Lock()
	previous := h.live
	h.mu.Unlock()
	if previous != nil {
		owner := sameID(previous.peer.ID, second.Sender.ID) && previous.peer.Fingerprint == second.Sender.Fingerprint
		if !owner || !h.store.isTrusted(second.Sender) {
			send(offer.SessionID, "hostBusy", fields{"hostID": h.id.peer.ID, "activeSessionID": previous.id})
			h.debug.add(attempt, "session.busy")
			return
		}
		previous.cancel()
		wait := time.NewTimer(3 * time.Second)
		defer wait.Stop()
		select {
		case <-ctx.Done():
			return
		case <-wait.C:
			return
		case <-previous.finished:
		}
		h.debug.add(attempt, "session.replaced")
	}
	if !h.pair(ctx, second.Sender, attempt) {
		return
	}
	if ctx.Err() != nil {
		return
	}
	if !h.desktop.active.Load() {
		send(offer.SessionID, "permissionBlocked", fields{"sessionID": offer.SessionID, "blockedPermissions": []any{}})
		h.debug.add(attempt, "desktop.unavailable")
		return
	}
	session := newSession(ctx, h, offer, second.Sender, token, attempt)
	defer session.cancel()
	h.mu.Lock()
	if h.live != nil || h.pending != nil || !h.store.isTrusted(second.Sender) {
		h.mu.Unlock()
		return
	}
	h.live = session
	h.mu.Unlock()
	defer func() {
		h.mu.Lock()
		h.live = nil
		h.mu.Unlock()
		close(session.finished)
		h.debug.add(attempt, "session.closed")
	}()
	session.serve(conn.RemoteAddr().(*net.TCPAddr).IP, send)
}

func (h *host) listen(signaling, secure *net.TCPListener) error {
	psk, err := hkdf.Key(sha256.New, []byte(h.id.peer.Fingerprint), []byte("com.remotedesktop.psk.salt.v1"), "connection-encryption", 32)
	if err != nil {
		return err
	}
	var workers sync.WaitGroup
	var clientsMutex sync.Mutex
	clients := make(map[string]int)
	limit := make(chan struct{}, 8)
	accept := func(listener *net.TCPListener, tls bool) {
		defer workers.Done()
		for {
			conn, err := listener.AcceptTCP()
			if err != nil {
				h.cancel()
				return
			}
			if !h.net.allows(conn.RemoteAddr().(*net.TCPAddr).IP) {
				conn.Close()
				continue
			}
			remote := conn.RemoteAddr().(*net.TCPAddr).IP.String()
			clientsMutex.Lock()
			if clients[remote] >= 2 {
				clientsMutex.Unlock()
				conn.Close()
				continue
			}
			select {
			case limit <- struct{}{}:
				clients[remote]++
				clientsMutex.Unlock()
				workers.Add(1)
				go func() {
					defer workers.Done()
					defer func() {
						clientsMutex.Lock()
						clients[remote]--
						if clients[remote] == 0 {
							delete(clients, remote)
						}
						clientsMutex.Unlock()
						<-limit
					}()
					h.signaling(conn, tls, psk)
				}()
			default:
				clientsMutex.Unlock()
				conn.Close()
			}
		}
	}
	workers.Add(2)
	go accept(signaling, false)
	go accept(secure, true)
	<-h.ctx.Done()
	signaling.Close()
	secure.Close()
	workers.Wait()
	return nil
}

func (h *host) advertise(path string) error {
	args := []string{h.id.peer.Name, "_screenharbor._tcp", strconv.Itoa(plainPort),
		"pv=1", "hostID=" + h.id.peer.ID, "name=" + h.id.peer.Name, "app=" + version, "port=9471",
		"codecs=h264", "availability=available", "fp=" + h.id.peer.Fingerprint,
		"stlsp=9473", "kapk=" + base64.StdEncoding.EncodeToString(h.id.agreement.PublicKey().Bytes()),
		"caps=supportsH264,supportsMultiDisplay,supportsAppStreaming,supportsDesktopControl,supportsMacClient",
	}
	if h.net.tailnet {
		args = append(args, "tsIP="+h.net.ip.String())
	}
	cmd := exec.CommandContext(h.ctx, path, args...)
	if err := cmd.Start(); err != nil {
		return err
	}
	h.debug.add(0, "discovery.started")
	h.discovery.Store(true)
	go func() {
		err := cmd.Wait()
		h.discovery.Store(false)
		if h.ctx.Err() == nil {
			h.debug.add(0, "discovery.failed")
			fmt.Fprintln(h.logWriter(), "Avahi publisher exited. Connect by address.")
		} else if err == nil {
			h.debug.add(0, "discovery.stopped")
		}
	}()
	return nil
}

var panelMode bool

func run() error {
	base, err := os.UserConfigDir()
	if err != nil {
		return err
	}
	bind := flag.String("bind", "127.0.0.1", "local LAN or tailscale0 IPv4 address")
	name := flag.String("name", "Vamp Sync (Linux)", "name shown in Vamp clients")
	stateDir := flag.String("state-dir", base+"/vamp-sync-linux", "private directory for identity, trust and diagnostic exports")
	input := flag.Bool("control", false, "allow remote input from explicitly paired devices")
	discovery := flag.Bool("discover", false, "publish LAN service using Avahi")
	clipboard := flag.Bool("clipboard", false, "enable plaintext clipboard sharing for paired control clients")
	showVersion := flag.Bool("version", false, "print the host version")
	var apps launchApps
	flag.BoolVar(&panelMode, "panel-events", false, "emit companion status as JSON")
	flag.Var(&apps, "app", "locally allowed app to launch (desktop-id,WM_CLASS,Name; repeatable)")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return nil
	}
	if runtime.GOOS != "linux" {
		return errors.New("Vamp Sync for Linux requires a Linux X11 desktop")
	}
	if os.Geteuid() == 0 {
		return errors.New("run from the desktop session as a regular user")
	}
	if flag.NArg() != 0 || len(*name) == 0 || len(*name) > 63 || strings.HasPrefix(*name, "-") ||
		strings.ContainsAny(*name, "\r\n\t\x1b") {
		return errors.New("invalid arguments or discovery name")
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	scope, err := scopeFor(*bind)
	if err != nil {
		return err
	}
	if *discovery && (scope.ip.IsLoopback() || scope.tailnet) {
		return errors.New("Avahi discovery requires a LAN bind address")
	}
	if !localDisplay.MatchString(os.Getenv("DISPLAY")) || !sessionName.MatchString(os.Getenv("XDG_SESSION_ID")) {
		return errors.New("start from a local X11 login session with DISPLAY and XDG_SESSION_ID set")
	}
	loginctl, err := exec.LookPath("loginctl")
	if err != nil {
		return err
	}
	guard := &desktopGuard{id: os.Getenv("XDG_SESSION_ID"), display: os.Getenv("DISPLAY"), loginctl: loginctl}
	guard.active.Store(guard.check(ctx))
	if !guard.active.Load() {
		return errors.New("an active, unlocked local X11 logind session is required")
	}
	d, err := openDesktop()
	if err != nil {
		return err
	}
	ready := d.unlocked() && (!*input || d.inputAvailable())
	d.close()
	if !ready {
		return errors.New("X11 Screen Saver and, for remote input, XTEST must be available")
	}
	var clipboardTool string
	if *clipboard {
		if !*input {
			return errors.New("--clipboard requires --control")
		}
		clipboardTool, err = exec.LookPath("xclip")
		if err != nil {
			return err
		}
	}
	var launcher string
	if len(apps) > 0 {
		if !*input {
			return errors.New("--app requires --control")
		}
		launcher, err = exec.LookPath("gtk-launch")
		if err != nil {
			return err
		}
	}
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		return err
	}
	// Reject a second process before opening or creating host identity state.
	plain, err := scope.listen(plainPort)
	if err != nil {
		return err
	}
	defer plain.Close()
	encrypted, err := scope.listen(securePort)
	if err != nil {
		return err
	}
	defer encrypted.Close()
	releaseState, err := lockStateDir(*stateDir)
	if err != nil {
		return err
	}
	defer releaseState()
	store, err := loadState(*stateDir)
	if err != nil {
		return err
	}
	id, err := store.identity(*name)
	if err != nil {
		return err
	}
	tls, err := newTLSContext()
	if err != nil {
		return err
	}
	defer tls.close()
	h := &host{ctx: ctx, cancel: stop, id: id, store: store, tls: tls, net: scope, desktop: guard, ffmpeg: ffmpeg, input: *input, apps: apps, launcher: launcher, clipboard: clipboardTool,
		debug: &debugger{start: time.Now(), input: *input, discovery: *discovery, clipboard: *clipboard}, replay: replayCache{ids: map[string]time.Time{}}}
	if panelMode {
		h.panel = &panelOutput{sink: os.Stdout}
	}
	h.debug.add(0, "host.ready")
	if *discovery {
		publisher, err := exec.LookPath("avahi-publish-service")
		if err != nil {
			return err
		}
		if err := h.advertise(publisher); err != nil {
			return err
		}
	}
	go func() {
		ticker := time.NewTicker(500 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				ok := guard.check(ctx)
				if previous := guard.active.Swap(ok); ok != previous {
					if ok {
						h.debug.add(0, "desktop.available")
					} else {
						h.debug.add(0, "desktop.unavailable")
						h.mu.Lock()
						if h.live != nil {
							h.live.cancel()
						}
						h.mu.Unlock()
					}
				}
				h.snapshotForPanel()
			}
		}
	}()
	h.snapshotForPanel()
	fmt.Fprintf(h.logWriter(), "%s listening on %s:%d (signed signaling), :%d (TLS signaling)\nHost fingerprint: %s\nType diagnose to export a tester report. Type quit to stop.\n",
		*name, *bind, plainPort, securePort, id.peer.Fingerprint)
	go h.console(os.Stdin)
	return h.listen(plain, encrypted)
}

func main() {
	if err := run(); err != nil {
		if panelMode {
			(&panelOutput{sink: os.Stdout}).emit(fields{"type": "error", "message": err.Error()})
		}
		fmt.Fprintln(os.Stderr, "Vamp Sync:", err)
		os.Exit(1)
	}
}
