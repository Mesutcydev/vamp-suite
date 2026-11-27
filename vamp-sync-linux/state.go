package main

import (
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
)

type state struct {
	dir      string
	mu       sync.Mutex
	ID       string            `json:"id"`
	Identity []byte            `json:"identity"`
	Trusted  map[string]string `json:"trusted"`
	Names    map[string]string `json:"deviceNames,omitempty"`
}

func privateStateDir(dir string) error {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	info, err := os.Lstat(dir)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return errors.New("state directory must be a private directory (0700)")
	}
	return nil
}

func lockStateDir(dir string) (func(), error) {
	if err := privateStateDir(dir); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(filepath.Join(dir, "host.lock"), os.O_RDWR|os.O_CREATE|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		file.Close()
		return nil, errors.New("another host is using this state directory")
	}
	return func() { file.Close() }, nil
}

func loadState(dir string) (*state, error) {
	if err := privateStateDir(dir); err != nil {
		return nil, err
	}
	s := &state{dir: dir, Names: make(map[string]string)}
	name := filepath.Join(dir, "state.json")
	info, err := os.Lstat(name)
	if err == nil {
		if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 1<<20 {
			return nil, errors.New("state file must be a private regular file")
		}
		data, err := os.ReadFile(name)
		if err != nil {
			return nil, err
		}
		if json.Unmarshal(data, s) != nil || !uuidPattern.MatchString(s.ID) || s.Trusted == nil {
			return nil, errors.New("invalid state file")
		}
		return s, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	s.Identity, err = x509.MarshalECPrivateKey(key)
	if err != nil {
		return nil, err
	}
	s.ID, s.Trusted = uuid(), make(map[string]string)
	return s, s.save()
}

func (s *state) save() error {
	data, err := json.Marshal(s)
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(s.dir, ".state-")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	_, writeErr := file.Write(data)
	if err := errors.Join(writeErr, file.Sync(), file.Close()); err != nil {
		return err
	}
	return os.Rename(file.Name(), filepath.Join(s.dir, "state.json"))
}

func (s *state) isTrusted(p peer) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return sameID(s.Trusted[p.Fingerprint], p.ID)
}

func (s *state) trust(p peer) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if existing := s.Trusted[p.Fingerprint]; existing != "" && !sameID(existing, p.ID) {
		return errors.New("peer identity changed")
	}
	if len(s.Trusted) >= 256 {
		return errors.New("trust store full")
	}
	oldID, oldName := s.Trusted[p.Fingerprint], s.Names[p.Fingerprint]
	s.Trusted[p.Fingerprint] = strings.ToUpper(p.ID)
	if s.Names == nil {
		s.Names = make(map[string]string)
	}
	s.Names[p.Fingerprint] = strings.TrimSpace(p.Name)
	if err := s.save(); err != nil {
		if oldID != "" {
			s.Trusted[p.Fingerprint], s.Names[p.Fingerprint] = oldID, oldName
		} else {
			delete(s.Trusted, p.Fingerprint)
			delete(s.Names, p.Fingerprint)
		}
		return err
	}
	return nil
}

func (s *state) revoke(fp string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	old, oldName := s.Trusted[fp], s.Names[fp]
	delete(s.Trusted, fp)
	delete(s.Names, fp)
	if err := s.save(); err != nil {
		if old != "" {
			s.Trusted[fp] = old
			if s.Names == nil {
				s.Names = make(map[string]string)
			}
			s.Names[fp] = oldName
		}
		return err
	}
	return nil
}

func (s *state) identity(name string) (identity, error) {
	key, err := x509.ParseECPrivateKey(s.Identity)
	if err != nil {
		return identity{}, err
	}
	dh, err := key.ECDH()
	if err != nil {
		return identity{}, err
	}
	public := dh.PublicKey().Bytes()
	material := append(append([]byte(nil), public...), dh.Bytes()...)
	for i := byte('0'); i <= '8'; i++ {
		raw, err := hkdf.Key(sha256.New, material, []byte(sealingSalt), sealingInfo+"attempt-"+string(i), 32)
		if err != nil {
			return identity{}, err
		}
		agreement, err := ecdh.P256().NewPrivateKey(raw)
		if err == nil {
			return identity{key, agreement, public, peer{s.ID, "host", name, fingerprint(public)}}, nil
		}
	}
	return identity{}, errors.New("key agreement derivation failed")
}
