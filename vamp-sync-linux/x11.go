package main

/*
#cgo pkg-config: x11 x11-xcb xcb xcb-composite xcb-xtest xcb-screensaver
#include "x11.h"
#include <stdlib.h>
*/
import "C"

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
	"sync"
	"unsafe"
)

var errX11 = errors.New("X11 operation failed")
var initX11 = sync.OnceValue(func() bool { return C.vamp_init_x11() == 1 })

type xDesktop struct{ display *C.Display }
type geometry struct{ X, Y, Width, Height int }

func openDesktop() (*xDesktop, error) {
	if !initX11() {
		return nil, errX11
	}
	d := C.XOpenDisplay(nil)
	if d == nil {
		return nil, errX11
	}
	return &xDesktop{d}, nil
}

func (d *xDesktop) close()               { C.XCloseDisplay(d.display) }
func (d *xDesktop) unlocked() bool       { return C.vamp_unlocked(d.display) != 0 }
func (d *xDesktop) inputAvailable() bool { return C.vamp_xtest(d.display) != 0 }

func (d *xDesktop) bounds(window uint32) (geometry, error) {
	var g C.vamp_geometry
	if C.vamp_geometry_for(d.display, C.Window(window), &g) == 0 {
		return geometry{}, errX11
	}
	return geometry{int(g.x), int(g.y), int(g.width), int(g.height)}, nil
}

func (d *xDesktop) windows() ([]application, error) {
	var ids [512]C.Window
	count := int(C.vamp_windows(d.display, &ids[0], C.int(len(ids))))
	if count < 0 {
		return nil, errX11
	}
	list := make([]application, 0, count)
	for _, id := range ids[:count] {
		if _, err := d.bounds(uint32(id)); err != nil {
			continue
		}
		title := d.windowTitle(uint32(id))
		if title == "" {
			continue
		}
		key := strconv.FormatUint(uint64(id), 10)
		var buffer [256]byte
		classLen := int(C.vamp_window_class(d.display, id, (*C.char)(unsafe.Pointer(&buffer[0])), C.int(len(buffer))))
		list = append(list, application{Bundle: "x11-" + key, Name: title, Running: true, Windows: []string{key}, class: string(buffer[:classLen])})
	}
	return list, nil
}

func (d *xDesktop) windowTitle(id uint32) string {
	var buffer [256]byte
	length := int(C.vamp_window_name(d.display, C.Window(id), (*C.char)(unsafe.Pointer(&buffer[0])), C.int(len(buffer))))
	return strings.TrimSpace(strings.ToValidUTF8(string(bytes.ReplaceAll(buffer[:length], []byte{0}, nil)), "�"))
}

type inputState struct {
	d                *xDesktop
	keys             map[int][]int
	keyRefs          map[int]int
	buttons          map[int]bool
	scrollX, scrollY float64
}

var macKeys = map[uint16]string{
	0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b",
	12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4",
	22: "6", 23: "5", 24: "equal", 25: "9", 26: "7", 27: "minus", 28: "8", 29: "0",
	30: "bracketright", 31: "o", 32: "u", 33: "bracketleft", 34: "i", 35: "p", 36: "Return",
	37: "l", 38: "j", 39: "apostrophe", 40: "k", 41: "semicolon", 42: "backslash", 43: "comma",
	44: "slash", 45: "n", 46: "m", 47: "period", 48: "Tab", 49: "space", 50: "grave", 51: "BackSpace",
	53: "Escape", 55: "Control_L", 56: "Shift_L", 58: "Alt_L", 59: "Control_L", 60: "Shift_R",
	61: "Alt_R", 62: "Control_R", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
	103: "F11", 109: "F10", 111: "F12", 115: "Home", 116: "Page_Up", 117: "Delete",
	118: "F4", 119: "End", 120: "F2", 121: "Page_Down", 122: "F1",
	123: "Left", 124: "Right", 125: "Down", 126: "Up",
}

var asciiSymbols = map[rune]string{
	' ': "space", '!': "exclam", '"': "quotedbl", '#': "numbersign", '$': "dollar",
	'%': "percent", '&': "ampersand", '\'': "apostrophe", '(': "parenleft", ')': "parenright",
	'*': "asterisk", '+': "plus", ',': "comma", '-': "minus", '.': "period", '/': "slash",
	':': "colon", ';': "semicolon", '<': "less", '=': "equal", '>': "greater", '?': "question",
	'@': "at", '[': "bracketleft", '\\': "backslash", ']': "bracketright", '^': "asciicircum",
	'_': "underscore", '`': "grave", '{': "braceleft", '|': "bar", '}': "braceright", '~': "asciitilde",
	'\n': "Return", '\t': "Tab",
}

func (s *inputState) keycode(symbol string) int {
	name := C.CString(symbol)
	defer C.free(unsafe.Pointer(name))
	return int(C.vamp_keycode(s.d.display, name))
}

func (s *inputState) keyLevel(code int, symbol string) int {
	name := C.CString(symbol)
	defer C.free(unsafe.Pointer(name))
	return int(C.vamp_key_level(s.d.display, C.int(code), name))
}

func (s *inputState) key(window uint32, code int, down bool) bool {
	return C.vamp_key(s.d.display, C.Window(window), C.int(code), cBool(down)) != 0
}

func cBool(value bool) C.int {
	if value {
		return 1
	}
	return 0
}

func (s *inputState) button(window uint32, button int, down bool) bool {
	return C.vamp_button(s.d.display, C.Window(window), C.int(button), cBool(down)) != 0
}

func (s *inputState) release() {
	for code := range s.keyRefs {
		s.key(0, code, false)
	}
	for button := range s.buttons {
		s.button(0, button, false)
	}
	clear(s.keys)
	clear(s.keyRefs)
	clear(s.buttons)
	s.scrollX, s.scrollY = 0, 0
}

func (s *inputState) releaseKeys(codes []int) {
	for _, code := range codes {
		s.keyRefs[code]--
		if s.keyRefs[code] == 0 {
			s.key(0, code, false)
			delete(s.keyRefs, code)
		}
	}
}

func (s *inputState) pressKeys(window uint32, codes []int) ([]int, error) {
	pressed := make([]int, 0, len(codes))
	for _, code := range codes {
		if code == 0 || (s.keyRefs[code] == 0 && !s.key(window, code, true)) {
			s.releaseKeys(pressed)
			return nil, errX11
		}
		s.keyRefs[code]++
		pressed = append(pressed, code)
	}
	return pressed, nil
}

type point struct{ X, Y float64 }

func (s *inputState) move(window uint32, g geometry, p point, absolute bool) error {
	if math.Abs(p.X) > 32767 || math.Abs(p.Y) > 32767 ||
		(absolute && (p.X < 0 || p.Y < 0 || p.X >= float64(g.Width) || p.Y >= float64(g.Height))) ||
		C.vamp_move(s.d.display, C.Window(window), C.int(p.X), C.int(p.Y), cBool(!absolute)) == 0 {
		return errX11
	}
	return nil
}

func (s *inputState) inject(window uint32, g geometry, session, display string, body []byte) error {
	var request struct {
		SessionID string
		Command   map[string]map[string]json.RawMessage
	}
	if json.Unmarshal(body, &request) != nil || !sameID(request.SessionID, session) || len(request.Command) != 1 {
		return invalidWire
	}
	for kind, wrapped := range request.Command {
		if len(wrapped) != 1 {
			return invalidWire
		}
		raw := wrapped["_0"]
		switch kind {
		case "pointerMove", "pointerButton":
			var p struct {
				Location       *point
				DisplayID      string
				IsAbsolute     *bool
				Button, Action string
			}
			if json.Unmarshal(raw, &p) != nil || (p.DisplayID != "" && p.DisplayID != display) {
				return invalidWire
			}
			if kind == "pointerMove" {
				if p.Location == nil || p.IsAbsolute == nil || p.DisplayID != display {
					return invalidWire
				}
				return s.move(window, g, *p.Location, *p.IsAbsolute)
			}
			button := map[string]int{"left": 1, "middle": 2, "right": 3}[p.Button]
			if button == 0 {
				return invalidWire
			}
			if p.Action == "up" {
				if s.buttons[button] {
					s.button(0, button, false)
					delete(s.buttons, button)
				}
				return nil
			}
			if p.Location != nil && s.move(window, g, *p.Location, true) != nil {
				return errX11
			}
			switch p.Action {
			case "down":
				if !s.button(window, button, true) {
					return errX11
				}
				s.buttons[button] = true
			case "click", "doubleClick":
				count := 1
				if p.Action == "doubleClick" {
					count = 2
				}
				for range count {
					if !s.button(window, button, true) {
						return errX11
					}
					s.button(0, button, false)
				}
			default:
				return invalidWire
			}
		case "scroll":
			var delta struct {
				DeltaX, DeltaY float64
				IsPrecise      bool
			}
			if json.Unmarshal(raw, &delta) != nil || math.Abs(delta.DeltaX) > 1000 || math.Abs(delta.DeltaY) > 1000 {
				return invalidWire
			}
			divisor := 1.0
			if delta.IsPrecise {
				divisor = 30
			}
			for index, axis := range []*float64{&s.scrollY, &s.scrollX} {
				*axis += []float64{delta.DeltaY / divisor, delta.DeltaX / divisor}[index]
				ticks := max(-8, min(8, int(*axis)))
				*axis = math.Mod(*axis, 1)
				button := 4 + index*2
				if ticks < 0 {
					button++
					ticks = -ticks
				}
				for range ticks {
					if !s.button(window, button, true) {
						return errX11
					}
					s.button(0, button, false)
				}
			}
		case "key":
			var k struct {
				KeyCode   *uint16
				Action    string
				Modifiers uint8
			}
			if json.Unmarshal(raw, &k) != nil || k.KeyCode == nil || k.Modifiers > 31 {
				return invalidWire
			}
			code := int(*k.KeyCode)
			if k.Action == "up" {
				s.releaseKeys(s.keys[code])
				delete(s.keys, code)
				return nil
			}
			if k.Action != "down" || macKeys[*k.KeyCode] == "" {
				return invalidWire
			}
			if _, held := s.keys[code]; held {
				return nil
			}
			var codes []int
			for _, mod := range []struct {
				mask   uint8
				symbol string
			}{{9, "Control_L"}, {2, "Shift_L"}, {4, "Alt_L"}} {
				if k.Modifiers&mod.mask != 0 {
					codes = append(codes, s.keycode(mod.symbol))
				}
			}
			codes = append(codes, s.keycode(macKeys[*k.KeyCode]))
			pressed, err := s.pressKeys(window, codes)
			if err != nil {
				return err
			}
			s.keys[code] = pressed
		case "text":
			var message struct{ Text string }
			if json.Unmarshal(raw, &message) != nil || len(message.Text) > 256 {
				return invalidWire
			}
			var chords [][]int
			for _, r := range message.Text {
				symbol := asciiSymbols[r]
				if symbol == "" {
					if r >= '0' && r <= '9' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' {
						symbol = string(r)
					} else {
						symbol = fmt.Sprintf("U%04X", r)
					}
				}
				code := s.keycode(symbol)
				if code == 0 {
					return errX11
				}
				switch s.keyLevel(code, symbol) {
				case 0:
					chords = append(chords, []int{code})
				case 1:
					chords = append(chords, []int{s.keycode("Shift_L"), code})
				default:
					return errX11
				}
			}
			for _, chord := range chords {
				pressed, err := s.pressKeys(window, chord)
				if err != nil {
					return err
				}
				s.releaseKeys(pressed)
			}
		default:
			return invalidWire
		}
	}
	return nil
}

func (d *xDesktop) pixels(window uint32, g geometry) (func([]byte) error, func(), error) {
	var pixmap C.Pixmap
	release := func() {}
	if window != 0 {
		pixmap = C.vamp_capture_window(d.display, C.Window(window))
		if pixmap == 0 {
			return nil, nil, errX11
		}
		release = func() { C.vamp_release_window(d.display, C.Window(window), pixmap) }
	}
	return func(buffer []byte) error {
		if C.vamp_frame(d.display, C.Drawable(pixmap), C.int(g.Width), C.int(g.Height), unsafe.Pointer(&buffer[0])) == 0 {
			return errX11
		}
		return nil
	}, release, nil
}

func (d *xDesktop) activate(window uint32) {
	C.vamp_activate(d.display, C.Window(window))
}

func (d *xDesktop) requestClose(window uint32) bool {
	return C.vamp_request_close(d.display, C.Window(window)) != 0
}

func (d *xDesktop) resize(window uint32, w, h int) bool {
	return C.vamp_resize(d.display, C.Window(window), C.int(w), C.int(h)) != 0
}
