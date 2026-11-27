package main

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSignedSignalAndReplay(t *testing.T) {
	s, err := loadState(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	client, err := s.identity("Client & Lab / 📱")
	if err != nil {
		t.Fatal(err)
	}
	client.peer.Role = "client"
	id := uuid()
	raw, err := client.signed(id, "hostKeyRequest", fields{"nonce": make([]byte, 32)})
	if err != nil {
		t.Fatal(err)
	}
	r := replayCache{ids: map[string]time.Time{}}
	envelope, err := r.verify(raw, peer{ID: uuid(), Role: "host"})
	if err != nil || !sameID(envelope.SessionID, id) {
		t.Fatalf("first signed request: %v", err)
	}
	if _, err := r.verify(raw, peer{}); err == nil {
		t.Fatal("accepted replay")
	}
	tampered := bytes.Replace(raw, []byte("Client"), []byte("Other "), 1)
	if _, err := r.verify(tampered, peer{}); err == nil {
		t.Fatal("accepted tampering")
	}
}

func TestSwiftWireFixtures(t *testing.T) {
	raw, err := os.ReadFile("testdata/swift-offer.json")
	if err != nil {
		t.Fatal(err)
	}
	var msg signalMessage
	if err := json.Unmarshal(raw, &msg); err != nil {
		t.Fatal(err)
	}
	r := replayCache{ids: map[string]time.Time{}}
	// Fixture predates the live replay window. Check its signature first,
	// then apply freshness independently to that same signed envelope.
	e, err := verifySignal(raw, peer{})
	if err != nil {
		t.Fatal(err)
	}
	if r.admit(e.ID, e.SentAt) {
		t.Fatal("accepted old offer")
	}
	var offer sessionOffer
	if eventBody(e, "offer", &offer) != nil || !offer.valid() {
		t.Fatal("invalid Swift offer")
	}
	var c control
	raw, err = os.ReadFile("testdata/swift-control.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &c); err != nil {
		t.Fatal(err)
	}
	key, err := hex.DecodeString(strings.Repeat("42", 32))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(c.Tag, c.mac(key)) {
		t.Fatalf("Swift MAC mismatch at %.16g", c.Timestamp)
	}
	c.Timestamp = wireTime()
	c.Tag = c.mac(key)
	if !c.valid(key, c.Counter-1) || c.valid(key, c.Counter) {
		t.Fatal("control counter validation")
	}
}

func TestTrustPersistsAndRevokes(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	s, err := loadState(dir)
	if err != nil {
		t.Fatal(err)
	}
	p := peer{ID: uuid(), Fingerprint: strings.Repeat("3", 64)}
	if s.isTrusted(p) {
		t.Fatal("unknown peer trusted")
	}
	if err := s.trust(p); err != nil {
		t.Fatal(err)
	}
	next, err := loadState(dir)
	if err != nil {
		t.Fatal(err)
	}
	if !next.isTrusted(p) {
		t.Fatal("pairing didn't persist")
	}
	other := p
	other.ID = uuid()
	if next.isTrusted(other) || next.trust(other) == nil {
		t.Fatal("accepted changed peer ID")
	}
	if err := next.revoke(p.Fingerprint); err != nil {
		t.Fatal(err)
	}
	if next.isTrusted(p) {
		t.Fatal("revocation didn't take effect")
	}
}

func TestVideoWireAndAnnexB(t *testing.T) {
	nals := []byte{0, 0, 0, 1, 9, 0x10, 0, 0, 1, 0x67, 0xfa, 0, 0, 0, 1, 0x68, 0xee,
		0, 0, 1, 0x65, 0xb1, 0, 0, 1, 0x65, 0xb2, 0, 0, 0, 1, 9, 0x10, 0, 0, 1, 0x41, 0xf0}
	var frames []encodedFrame
	if err := readH264(bytes.NewReader(nals), func(f encodedFrame) error { frames = append(frames, f); return nil }); err != nil {
		t.Fatal(err)
	}
	if len(frames) != 2 || !frames[0].key || frames[1].key {
		t.Fatalf("unexpected frames %#v", frames)
	}
	wire := videoWire(frames[0], 7, 1.5, 640, 480)
	if !bytes.Equal(wire[:5], []byte{'V', 'F', 2, 0, 1}) || binary.BigEndian.Uint16(wire[32:34]) != 12 ||
		binary.BigEndian.Uint64(wire[8:16]) != 7 || binary.BigEndian.Uint32(wire[24:28]) != 640 ||
		!bytes.Equal(wire[46:], []byte{0, 0, 0, 2, 0x65, 0xb1, 0, 0, 0, 2, 0x65, 0xb2}) {
		t.Fatalf("unexpected encoded payload %x", wire)
	}
}

func TestDebuggerRingAndLocalExport(t *testing.T) {
	d := debugger{start: time.Now(), input: true}
	for i := 0; i < breadcrumbLimit+30; i++ {
		d.add(1, "test.event", i)
	}
	r := d.snapshot()
	if len(r.Breadcrumbs) != breadcrumbLimit || r.Dropped != 30 || r.Breadcrumbs[0].Sequence != 31 ||
		*r.Breadcrumbs[0].Value != 30 || !r.InputEnabled {
		t.Fatalf("unexpected report header %+v", r.Breadcrumbs[0])
	}
	file, err := d.export(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(file)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("export file security: %v", err)
	}
	raw, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	var copy diagnosticReport
	if err := json.Unmarshal(raw, &copy); err != nil || len(copy.Breadcrumbs) != breadcrumbLimit {
		t.Fatalf("export: %v", err)
	}
}

func TestBindScope(t *testing.T) {
	for _, ip := range []string{"0.0.0.0", "::", "203.0.113.1", "100.64.0.1"} {
		if _, err := scopeFor(ip); err == nil {
			t.Fatalf("accepted invalid bind address %s", ip)
		}
	}
	loop, err := scopeFor("127.0.0.1")
	if err != nil || !loop.allows(net.ParseIP("127.0.0.1")) || loop.allows(net.ParseIP("192.168.1.1")) {
		t.Fatal("loopback scope")
	}
}

func TestDuplicateKeysAreRejected(t *testing.T) {
	s, err := loadState(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	client, err := s.identity("")
	if err != nil {
		t.Fatal(err)
	}
	client.peer.Role = "client"
	raw, err := client.signed(uuid(), "hostKeyRequest", fields{"nonce": make([]byte, 32)})
	if err != nil {
		t.Fatal(err)
	}
	r := replayCache{ids: map[string]time.Time{}}
	// A valid message still verifies.
	if _, err := r.verify(raw, peer{ID: uuid(), Role: "host"}); err != nil {
		t.Fatalf("valid message rejected: %v", err)
	}
	// Prepending a second "envelope" object used to leave the signature valid while merging
	// an unsigned displayName into the struct view of the message.
	forged := append([]byte(`{"envelope":{"sender":{"displayName":"Mesut's iPhone"}},`), raw[1:]...)
	r2 := replayCache{ids: map[string]time.Time{}}
	if _, err := r2.verify(forged, peer{ID: uuid(), Role: "host"}); err == nil {
		t.Fatal("accepted a message with a repeated key")
	}
	for _, bad := range []string{`{"a":1,"a":2}`, `{"a":{"b":1,"b":2}}`, `[{"a":1,"a":2}]`, `{"a":1} {"b":2}`} {
		if rejectDuplicateKeys([]byte(bad)) == nil {
			t.Fatalf("accepted %s", bad)
		}
	}
	if rejectDuplicateKeys([]byte(`{"a":[1,{"b":2}],"c":{"b":3}}`)) != nil {
		t.Fatal("rejected a message without repeated keys")
	}
}
