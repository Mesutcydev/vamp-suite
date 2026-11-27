package main

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const appleEpoch = 978307200
const wireLimit = 1 << 20
const sealingSalt = "vamp-hkdf-salt-v1"
const sealingInfo = "vamp-session-token-sealing-v1"

var invalidWire = errors.New("invalid wire message")
var uuidPattern = regexp.MustCompile(`(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

type fields = map[string]any

func uuid() string {
	var b [16]byte
	rand.Read(b[:])
	b[6], b[8] = b[6]&15|64, b[8]&63|128
	return strings.ToUpper(fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:]))
}

func wireTime() float64 {
	now := time.Now()
	return float64(now.Unix()-appleEpoch) + float64(now.Nanosecond())/1e9
}

func sameID(a, b string) bool {
	return uuidPattern.MatchString(a) && strings.EqualFold(a, b)
}

func digest(data []byte) []byte {
	sum := sha256.Sum256(data)
	return sum[:]
}

func fingerprint(key []byte) string { return hex.EncodeToString(digest(key)) }

type peer struct {
	ID          string `json:"id"`
	Role        string `json:"role"`
	Name        string `json:"displayName,omitempty"`
	Fingerprint string `json:"publicKeyFingerprint"`
}

type signalEnvelope struct {
	ID        string                                `json:"id"`
	Version   int                                   `json:"protocolVersion"`
	SentAt    float64                               `json:"sentAt"`
	SessionID string                                `json:"sessionID"`
	Sender    peer                                  `json:"sender"`
	Recipient *peer                                 `json:"recipient,omitempty"`
	Event     map[string]map[string]json.RawMessage `json:"event"`
}

type signalMessage struct {
	Minimum   int            `json:"minimumProtocolVersion"`
	Envelope  signalEnvelope `json:"envelope"`
	Key       []byte         `json:"senderPublicKey"`
	Signature []byte         `json:"signature"`
}

// The signed representation is Foundation JSONEncoder with sortedKeys and escaped slashes.
// Use a generic JSON tree for sorting nested object keys, including the synthesized enum.
func unsignedMessage(raw []byte) ([]byte, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var message map[string]any
	if err := decoder.Decode(&message); err != nil {
		return nil, err
	}
	delete(message, "senderPublicKey")
	delete(message, "signature")
	var result bytes.Buffer
	encoder := json.NewEncoder(&result)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(message); err != nil {
		return nil, err
	}
	return bytes.ReplaceAll(bytes.TrimSuffix(result.Bytes(), []byte("\n")), []byte("/"), []byte(`\/`)), nil
}

type replayCache struct {
	mu  sync.Mutex
	ids map[string]time.Time
}

func (r *replayCache) admit(id string, sentAt float64) bool {
	age := wireTime() - sentAt
	if age > 30 || age < -30 {
		return false
	}
	now := time.Now()
	r.mu.Lock()
	defer r.mu.Unlock()
	for key, received := range r.ids {
		if now.Sub(received) > time.Minute {
			delete(r.ids, key)
		}
	}
	id = strings.ToUpper(id)
	if _, exists := r.ids[id]; exists || len(r.ids) >= 20_000 {
		return false
	}
	r.ids[id] = now
	return true
}

func (r *replayCache) verify(raw []byte, host peer) (signalEnvelope, error) {
	e, err := verifySignal(raw, host)
	if err != nil || !r.admit(e.ID, e.SentAt) {
		return e, invalidWire
	}
	return e, nil
}

// rejectDuplicateKeys fails when any JSON object repeats a key. The signature is checked over a
// generic tree where the last duplicate wins, while the struct decoder merges duplicate objects, so
// a repeated key let a field the sender never signed (displayName, recipient) differ between the
// two views of the same message.
func rejectDuplicateKeys(raw []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	var walk func() error
	walk = func() error {
		token, err := decoder.Token()
		if err != nil {
			return err
		}
		delim, ok := token.(json.Delim)
		if !ok {
			return nil
		}
		switch delim {
		case '{':
			seen := map[string]bool{}
			for decoder.More() {
				keyToken, err := decoder.Token()
				if err != nil {
					return err
				}
				key, _ := keyToken.(string)
				if seen[key] {
					return invalidWire
				}
				seen[key] = true
				if err := walk(); err != nil {
					return err
				}
			}
			_, err = decoder.Token()
			return err
		case '[':
			for decoder.More() {
				if err := walk(); err != nil {
					return err
				}
			}
			_, err = decoder.Token()
			return err
		}
		return nil
	}
	if err := walk(); err != nil || decoder.More() {
		return invalidWire
	}
	return nil
}

func verifySignal(raw []byte, host peer) (signalEnvelope, error) {
	var m signalMessage
	if rejectDuplicateKeys(raw) != nil || json.Unmarshal(raw, &m) != nil {
		return m.Envelope, invalidWire
	}
	e := m.Envelope
	if m.Minimum != 1 || e.Version != 1 || e.SentAt == 0 || e.Sender.Role != "client" ||
		!uuidPattern.MatchString(e.ID) || !uuidPattern.MatchString(e.SessionID) ||
		!uuidPattern.MatchString(e.Sender.ID) || e.Sender.Fingerprint != fingerprint(m.Key) ||
		(e.Recipient != nil && (!sameID(e.Recipient.ID, host.ID) || e.Recipient.Role != "host")) {
		return e, invalidWire
	}
	pub, err := ecdh.P256().NewPublicKey(m.Key)
	if err != nil {
		return e, invalidWire
	}
	x, y := elliptic.Unmarshal(elliptic.P256(), pub.Bytes())
	key := &ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}
	unsigned, err := unsignedMessage(raw)
	if err != nil || !ecdsa.VerifyASN1(key, digest(unsigned), m.Signature) {
		return e, invalidWire
	}
	return e, nil
}

func eventBody(e signalEnvelope, kind string, dest any) error {
	body := e.Event[kind]
	if len(e.Event) != 1 || len(body) != 1 || body["_0"] == nil {
		return invalidWire
	}
	return json.Unmarshal(body["_0"], dest)
}

type identity struct {
	signing   *ecdsa.PrivateKey
	agreement *ecdh.PrivateKey
	public    []byte
	peer      peer
}

func (i identity) signed(session, kind string, payload any) ([]byte, error) {
	message := fields{
		"minimumProtocolVersion": 1,
		"envelope": fields{
			"id": uuid(), "protocolVersion": 1, "sentAt": wireTime(), "sessionID": session,
			"sender": i.peer, "event": fields{kind: fields{"_0": payload}},
		},
	}
	raw, err := json.Marshal(message)
	if err != nil {
		return nil, err
	}
	unsigned, err := unsignedMessage(raw)
	if err != nil {
		return nil, err
	}
	signature, err := ecdsa.SignASN1(rand.Reader, i.signing, digest(unsigned))
	if err != nil {
		return nil, err
	}
	message["signature"], message["senderPublicKey"] = signature, i.public
	return json.Marshal(message)
}

func (i identity) bundle(nonce []byte) (fields, error) {
	if len(nonce) < 16 || len(nonce) > 64 {
		return nil, invalidWire
	}
	transcript := []byte("vamp-host-key-bundle-v1")
	agreement := i.agreement.PublicKey().Bytes()
	for _, part := range [][]byte{nonce, i.public, agreement} {
		transcript = binary.BigEndian.AppendUint32(transcript, uint32(len(part)))
		transcript = append(transcript, part...)
	}
	signature, err := ecdsa.SignASN1(rand.Reader, i.signing, digest(transcript))
	return fields{"nonce": nonce, "signingPublicKey": i.public, "keyAgreementPublicKey": agreement, "signature": signature}, err
}

func (i identity) unseal(box []byte) ([]byte, error) {
	if len(box) != 1+65+12+32+16 || box[0] != 1 {
		return nil, invalidWire
	}
	pub, err := ecdh.P256().NewPublicKey(box[1:66])
	if err != nil {
		return nil, err
	}
	shared, err := i.agreement.ECDH(pub)
	if err != nil {
		return nil, err
	}
	key, err := hkdf.Key(sha256.New, shared, []byte(sealingSalt), sealingInfo, 32)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return gcm.Open(nil, box[66:78], box[78:], nil)
}

type control struct {
	Kind      string  `json:"kind"`
	SessionID string  `json:"sessionID,omitempty"`
	Timestamp float64 `json:"timestamp"`
	Payload   []byte  `json:"payload"`
	Counter   uint64  `json:"authCounter,omitempty"`
	Nonce     []byte  `json:"authNonce,omitempty"`
	Tag       []byte  `json:"authTag,omitempty"`
}

func (c control) mac(token []byte) []byte {
	mac := hmac.New(sha256.New, token)
	io.WriteString(mac, c.Kind)
	io.WriteString(mac, strings.ToUpper(c.SessionID))
	// Swift's Double description uses shortest round-trip notation and a .0 for integers.
	value := c.Timestamp + appleEpoch
	stamp := strconv.FormatFloat(value, 'f', -1, 64)
	if !strings.Contains(stamp, ".") {
		stamp += ".0"
	}
	io.WriteString(mac, stamp)
	mac.Write(c.Payload)
	io.WriteString(mac, strconv.FormatUint(c.Counter, 10))
	mac.Write(c.Nonce)
	return mac.Sum(nil)
}

func (c control) fresh() bool {
	age := wireTime() - c.Timestamp
	return c.Timestamp != 0 && age >= -5 && age <= 30
}

func (c control) valid(token []byte, previous uint64) bool {
	return c.fresh() && c.Counter > previous && c.Counter-previous <= 10_000 &&
		len(c.Nonce) == 12 && hmac.Equal(c.Tag, c.mac(token))
}

func packet(r io.Reader, tagged bool, limit uint32) (byte, []byte, error) {
	var header [5]byte
	start := 0
	if !tagged {
		start = 1
	}
	if _, err := io.ReadFull(r, header[start:]); err != nil {
		return 0, nil, err
	}
	size := binary.BigEndian.Uint32(header[1:])
	if size == 0 || size > limit {
		return 0, nil, invalidWire
	}
	payload := make([]byte, size)
	_, err := io.ReadFull(r, payload)
	return header[0], payload, err
}

func sendPacket(w io.Writer, tag byte, payload []byte, tagged bool) error {
	start := 0
	if !tagged {
		start = 1
	}
	var header [5]byte
	header[0] = tag
	binary.BigEndian.PutUint32(header[1:], uint32(len(payload)))
	if _, err := w.Write(header[start:]); err != nil {
		return err
	}
	_, err := w.Write(payload)
	return err
}

func videoWire(frame encodedFrame, sequence uint64, pts float64, width, height int) []byte {
	data := make([]byte, 34, 34+len(frame.parameters)+len(frame.sample))
	copy(data, []byte{'V', 'F', 2, 0})
	if frame.key {
		data[4] = 1
	}
	binary.BigEndian.PutUint64(data[8:], sequence)
	binary.BigEndian.PutUint64(data[16:], math.Float64bits(pts))
	binary.BigEndian.PutUint32(data[24:], uint32(width))
	binary.BigEndian.PutUint32(data[28:], uint32(height))
	binary.BigEndian.PutUint16(data[32:], uint16(len(frame.parameters)))
	data = append(data, frame.parameters...)
	return append(data, frame.sample...)
}
