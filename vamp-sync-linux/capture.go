package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"os/exec"
	"strconv"
	"time"
)

type encodedFrame struct {
	parameters, sample []byte
	key                bool
}

var nalStart = []byte{0, 0, 1}

func splitNAL(data []byte, eof bool) (int, []byte, error) {
	start := bytes.Index(data, nalStart)
	if start < 0 {
		if eof {
			if len(data) != 0 {
				return 0, nil, invalidWire
			}
			return 0, nil, nil
		}
		return 0, nil, nil
	}
	start += len(nalStart)
	next := bytes.Index(data[start:], nalStart)
	if next >= 0 {
		end := start + next
		return end, bytes.TrimRight(data[start:end], "\x00"), nil
	}
	if eof {
		return len(data), bytes.TrimRight(data[start:], "\x00"), nil
	}
	return 0, nil, nil
}

func readH264(reader io.Reader, deliver func(encodedFrame) error) error {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 32<<10), 4<<20)
	scanner.Split(splitNAL)
	var frame encodedFrame
	var hasVCL bool
	emit := func() error {
		if !hasVCL {
			return nil
		}
		err := deliver(frame)
		frame, hasVCL = encodedFrame{}, false
		return err
	}
	for scanner.Scan() {
		unit := scanner.Bytes()
		if len(unit) == 0 {
			continue
		}
		switch unit[0] & 31 {
		case 9: // AUD marks an access unit, including multi-slice frames.
			if err := emit(); err != nil {
				return err
			}
		case 7, 8:
			if len(frame.parameters)+4+len(unit) > 65535 {
				return invalidWire
			}
			frame.parameters = append(frame.parameters, 0, 0, 0, 1)
			frame.parameters = append(frame.parameters, unit...)
		case 1, 5:
			if len(frame.sample)+4+len(unit) > 8<<20 {
				return invalidWire
			}
			hasVCL = true
			frame.key = frame.key || unit[0]&31 == 5
			frame.sample = binary.BigEndian.AppendUint32(frame.sample, uint32(len(unit)))
			frame.sample = append(frame.sample, unit...)
		}
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	return emit()
}

type capture struct {
	stop          context.CancelFunc
	frames        <-chan encodedFrame
	done          <-chan struct{}
	width, height int
}

func dimensions(g geometry, preset string) (int, int) {
	w, h := 1920, 1080
	switch preset {
	case "performance":
		w, h = 1280, 720
	case "quality", "ultra":
		w, h = 2560, 1440
	}
	if g.Width*w == 0 || g.Height*h == 0 {
		return 0, 0
	}
	scale := min(1.0, float64(w)/float64(g.Width), float64(h)/float64(g.Height))
	return max(2, int(float64(g.Width)*scale)/2*2), max(2, int(float64(g.Height)*scale)/2*2)
}

func startCapture(parent context.Context, ffmpeg string, window uint32, g geometry, preset string, active func() bool) (*capture, error) {
	width, height := dimensions(g, preset)
	// Bound raw allocation and X11 readback work. The native capture backend
	// deliberately supports up to a 4K-class source in this version.
	if width == 0 || g.Width*g.Height > 4096*2304 {
		return nil, errX11
	}
	ctx, cancel := context.WithCancel(parent)
	cmd := exec.CommandContext(ctx, ffmpeg,
		"-hide_banner", "-loglevel", "error", "-nostdin",
		"-f", "rawvideo", "-pixel_format", "bgr0", "-video_size", strconv.Itoa(g.Width)+"x"+strconv.Itoa(g.Height),
		"-framerate", "24", "-i", "pipe:0", "-an",
		"-vf", "scale="+strconv.Itoa(width)+":"+strconv.Itoa(height), "-pix_fmt", "yuv420p",
		"-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
		"-threads", "2", "-g", "24", "-x264-params", "aud=1:repeat-headers=1",
		"-f", "h264", "pipe:1")
	input, err := cmd.StdinPipe()
	if err != nil {
		cancel()
		return nil, err
	}
	output, err := cmd.StdoutPipe()
	if err != nil {
		input.Close()
		cancel()
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		input.Close()
		output.Close()
		cancel()
		return nil, err
	}
	frames := make(chan encodedFrame, 2)
	done := make(chan struct{})
	captureDone := make(chan struct{})
	go func() {
		defer close(captureDone)
		defer input.Close()
		d, err := openDesktop()
		if err != nil {
			return
		}
		defer d.close()
		readPixels, release, err := d.pixels(window, g)
		if err != nil {
			return
		}
		defer release()
		tick := time.NewTicker(time.Second / 24)
		defer tick.Stop()
		buffer := make([]byte, g.Width*g.Height*4)
		for {
			if ctx.Err() != nil || !active() || !d.unlocked() {
				return
			}
			current, err := d.bounds(window)
			if err != nil || current.Width != g.Width || current.Height != g.Height {
				return
			}
			if readPixels(buffer) != nil {
				return
			}
			if _, err := input.Write(buffer); err != nil {
				return
			}
			select {
			case <-ctx.Done():
				return
			case <-tick.C:
			}
		}
	}()
	go func() {
		defer close(done)
		defer close(frames)
		readH264(output, func(frame encodedFrame) error {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case frames <- frame:
				return nil
			}
		})
		cancel()
		cmd.Wait()
		<-captureDone
	}()
	return &capture{cancel, frames, done, width, height}, nil
}

func (c *capture) first() (encodedFrame, error) {
	timer := time.NewTimer(4 * time.Second)
	defer timer.Stop()
	select {
	case frame, open := <-c.frames:
		if open && frame.key && len(frame.parameters) > 0 {
			return frame, nil
		}
		return encodedFrame{}, errors.New("encoder did not produce an initial keyframe")
	case <-timer.C:
		return encodedFrame{}, errors.New("encoder startup timed out")
	}
}
