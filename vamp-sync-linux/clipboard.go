package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os/exec"
	"time"
	"unicode/utf8"
)

const clipboardLimit = 1 << 16

type clipboardBuffer struct{ bytes.Buffer }

func (b *clipboardBuffer) Write(p []byte) (int, error) {
	if len(p) > clipboardLimit-b.Len() {
		return 0, invalidWire
	}
	return b.Buffer.Write(p)
}

func (s *session) clipboard(c control) error {
	if s.h.clipboard == "" || time.Since(s.lastClipboard) < 500*time.Millisecond {
		return nil
	}
	var body struct{ SessionID, Text, Source string }
	if json.Unmarshal(c.Payload, &body) != nil || !sameID(body.SessionID, s.id) {
		return nil
	}
	s.lastClipboard = time.Now()
	ctx, cancel := context.WithTimeout(s.ctx, time.Second)
	defer cancel()
	if c.Kind == "clipboardSync" {
		if body.Source != "client" || body.Text == "" || len(body.Text) > clipboardLimit {
			return nil
		}
		cmd := exec.CommandContext(ctx, s.h.clipboard, "-selection", "clipboard", "-in", "-silent")
		cmd.Stdin = bytes.NewBufferString(body.Text)
		if err := cmd.Run(); err != nil {
			s.mark("clipboard.failed")
			return nil
		}
		s.mark("clipboard.updated")
		return nil
	}
	cmd := exec.CommandContext(ctx, s.h.clipboard, "-selection", "clipboard", "-out", "-target", "UTF8_STRING")
	var result clipboardBuffer
	cmd.Stdout = &result
	if err := cmd.Run(); err != nil {
		s.mark("clipboard.failed")
		return nil
	}
	if !s.available() || result.Len() == 0 || !utf8.Valid(result.Bytes()) {
		return nil
	}
	s.mark("clipboard.sent")
	return s.send("clipboardSync", s.id, fields{"sessionID": s.id, "text": result.String(), "source": "host"}, true)
}
