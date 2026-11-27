package main

import (
	"context"
	"errors"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
)

type launchApp struct {
	id, class, name string
}

type launchApps []launchApp

var desktopEntryID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

func (a *launchApps) String() string { return "desktop-id,WM_CLASS,Name" }

func (a *launchApps) Set(value string) error {
	parts := strings.SplitN(value, ",", 3)
	if len(parts) != 3 || !desktopEntryID.MatchString(parts[0]) || len(parts[1]) == 0 || len(parts[1]) > 128 ||
		len(parts[2]) == 0 || len(parts[2]) > 128 || strings.ContainsFunc(parts[1]+parts[2], unicode.IsControl) {
		return errors.New("use --app desktop-id,WM_CLASS,Name")
	}
	if len(*a) >= 64 {
		return errors.New("at most 64 launch apps are allowed")
	}
	for _, configured := range *a {
		if configured.id == parts[0] || strings.EqualFold(configured.class, parts[1]) {
			return errors.New("desktop ID and window class must be unique")
		}
	}
	*a = append(*a, launchApp{parts[0], parts[1], parts[2]})
	return nil
}

func (s *session) inventory() ([]application, error) {
	list, err := s.input.d.windows()
	if err != nil || len(s.h.apps) == 0 {
		return list, err
	}
	registered := make([]application, len(s.h.apps))
	for i, app := range s.h.apps {
		registered[i] = application{Bundle: app.id, Name: app.name, Windows: []string{}, Titles: map[string]string{}}
	}
	unregistered := make([]application, 0, len(list))
	for _, window := range list {
		configured := -1
		for i, app := range s.h.apps {
			if strings.EqualFold(app.class, window.class) {
				configured = i
				break
			}
		}
		if configured < 0 {
			unregistered = append(unregistered, window)
			continue
		}
		app := &registered[configured]
		id := window.Windows[0]
		app.Windows = append(app.Windows, id)
		app.Titles[id] = window.Name
		app.Running = true
	}
	return append(registered, unregistered...), nil
}

func (s *session) windowFor(t target) (uint32, error) {
	list, err := s.inventory()
	if err != nil {
		return 0, err
	}
	for _, app := range list {
		for _, id := range app.Windows {
			if (t.Kind == "application" && t.Identifier == app.Bundle) || (t.Kind == "window" && t.Identifier == id) {
				n, err := strconv.ParseUint(id, 10, 32)
				if err != nil || n == 0 {
					return 0, errX11
				}
				return uint32(n), nil
			}
		}
	}
	return 0, nil
}

func (s *session) launch(t target) (uint32, error) {
	if !s.h.input || s.h.launcher == "" || t.Kind != "application" {
		return 0, nil
	}
	for _, app := range s.h.apps {
		if app.id != t.Identifier {
			continue
		}
		s.mark("capture.launch_requested")
		ctx, cancel := context.WithTimeout(s.ctx, 7*time.Second)
		defer cancel()
		if err := exec.CommandContext(ctx, s.h.launcher, "--", app.id).Run(); err != nil {
			return 0, err
		}
		tick := time.NewTicker(100 * time.Millisecond)
		defer tick.Stop()
		for s.available() {
			window, err := s.windowFor(t)
			if err != nil || window != 0 {
				return window, err
			}
			select {
			case <-ctx.Done():
				return 0, ctx.Err()
			case <-tick.C:
			}
		}
		return 0, errX11
	}
	return 0, nil
}
