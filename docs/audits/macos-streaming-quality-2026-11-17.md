# Vamp Control macOS — streaming resolution, quality, and window-sizing audit

Date: 2026-11-17. Scope: the macOS client and the Vamp Sync host-side streaming
paths it talks to — encode/capture resolution, quality presets and adaptation,
the session view sizing modes, and window/stream resizing behaviors.

## Evidence and limits

Source review of `MacClient/Sources` (session view, video surface, input
controller, quality policy) and `Sources/{SharedModels,EncodeEngine,CaptureEngine,HostApp}`
(`StreamScaling`, `EncoderConfiguration`, `AdaptiveStreamingController`,
`ScreenCaptureEngine`, `HostSessionCoordinator`). `swift build` and the 44-test
native Mac client suite pass with the fixes below applied. No live two-host
session was run during this audit; numbers below are read from code, not
measured on a stream. The 2026-09-05 UX audit's remaining items are out of scope.

## What is already sound (checked, not changed)

- Capture and encode dimensions share one source of truth (`StreamScaling`) —
  they cannot drift; HEVC unlocks the 4K cap for balanced/quality, H.264 stays at
  1080p; `ultra` passes native pixels through with a window-stream decoder
  ceiling (3840 long edge / 8.3 MP).
- The bitrate table (`w×h×fps×bpp`, HEVC ×0.75) replaced the old divide-by-30
  bug; the adaptive controller normalizes queue depth to seconds of latency,
  treats receiver-reported loss as the congestion signal, and decays quiet
  counters so bitrate recovers through periodic keyframe bursts.
- The Actual Size layer is pinned to the mapper's content rect, and letterbox /
  crop math in Fill Window maps cropped edges correctly (view point → normalized
  stream stays exact at the view borders).
- Fit/Fill/Actual + Match Window resize helpers clamp correctly against the
  visible frame; per-host preference storage works, and the one-time Quality
  promotion (`MacStreamingQualityPolicy`) is wired in `MacClientEnvironmentFactory`.

## Prioritized findings

| Priority | Finding and evidence | Recommendation | Acceptance |
| --- | --- | --- | --- |
| P1 (fixed) | In Actual Size mode the pinned layer rect only recomputed on layout/display-mode change. A mid-session quality change reconfigures the encoder and the next frames arrive at different dimensions — the picture stayed at the old 1:1 rect (stretched/clipped) and the input mapping disagreed until the window happened to relayout. `RemoteStreamNSView.layoutDisplayLayer` had no stream-size input. | Refresh the pinned rect on frame arrival with an equality guard (no per-frame CATransaction work). Implemented. | Change quality mid-session in Actual Size: the picture re-pins to the new dimensions on the first frame; no double-cursor or offset input. |
| P2 (fixed) | The Stream Quality sheet shows only preset names. The host silently floors the requested preset (thermal/power profile, `applyRuntimeQualityAdjust` enforces the host minimum), so the UI can claim Quality while the host encodes Balanced, and there is no way to see what is actually being sent. | Show the live truth in the sheet: actual encoded dimensions from the active stream configuration plus measured FPS ("Now streaming 2560×1440 @ 60 fps"). Implemented for desktop and app-window streams. | The sheet's line matches the host encoder diagnostics during a live session, including after a mid-session preset change. |
| P2 (fixed) | Adaptive app-window sizing is iOS-only UI. The Mac client always streams apps in `.adaptive` mode: the host reshapes the streamed window to the client viewport's aspect and scales it to fill the host display (capped at 1440 pt long edge), and every ≥2 px change of the client window re-requests it (300 ms debounce). Resizing the Control window visibly resizes the *host's* app window, and there was no way to turn that off on the Mac. | Expose the same Adaptive resize / Original Size choice the iOS client has, in the session source menu while an app window is streamed. Implemented (`AppStreamViewModel.setSizingMode` already supports both). | Switching to Original Size stops the host window from following client resizes; switching back to Adaptive restores fill behavior. |
| P2 | "Show All Displays" secondaries are always captured with `allowsHighResolution: false` at the `minQualityPreset(profile.effectivePreset, .balanced)` floor (`SecondaryDisplayStreamer.start`, `handleSetActiveDisplays`), even when HEVC is negotiated — so a focused secondary feeds the main surface from a ≤1920-px-wide source on a large display while the primary streams 4K. Deliberate HW budget caution, but it makes a focused secondary visibly softer than the primary. | When HEVC is negotiated, allow high-resolution secondaries (M-series media engines handle multiple 4K HEVC encodes); or reconfigure the focused secondary upward on `focusDisplay`. Gate by encoder instance count if needed. | Focused secondary pixel width ≥ primary pixel width × 0.75 on an HEVC session; parallel stream starts stay within the host's encoder session budget. |
| P2 | The status pill and Connection details present `coordinator.activeQualityPreset` — the client's *requested* preset (entitlement-adjusted at connect time). The host's actual configured preset is never published back, so the UI cannot show a thermal floor or a congestion-driven preset change. `HostStatusMessage.quality` carries only the network-quality enum. | Publish the host's actual preset (e.g. alongside the display configuration messages) and drive `activeQualityPreset` from it. Shared-protocol change — coordinate with the iOS client. | With the host thermally throttled to Balanced while the client requests Ultra, both pill and details read Balanced. |
| P3 | Frame-rate table: performance/balanced are pinned to 30 fps. On Mac-to-Mac LAN sessions (the dominant Control pairing) 60 fps at Balanced would suit desktop motion (window drags, video) better than the phone-derived default. | Consider a Mac-client default of 60 fps for Balanced on hosts with HEVC, keeping the congestion controller's severe-loss FPS cut. Needs a host-side frame-rate table keyed on client type. | Balanced Mac-to-Mac session shows ~60 fps in live stats without a preset bump; severe loss still drops to 30. |
| P3 | App-window resize churn: each settled resize costs a full capture+encoder restart (~0.5–1 s picture gap). The settle guard (one stable tick) bounds a drag to one restart, but a slow cross-display drag can still re-trigger. | Hysteresis: skip reconfigure when the settled size differs from the active descriptor by ≤ a few pixels, and coalesce restarts within ~1 s. | Dragging a streamed window edge across 200 px produces ≤1 restart and no visible gap at the end of the drag. |
| P3 | Match Window / Actual Size use `window.screen ?? NSScreen.main`; if the window later moves to a screen with a different backing scale, Actual Size keeps the old point size until the user re-triggers it. | Re-run the 1:1 fit when the window's screen changes (`NSWindow.didChangeScreenNotification`). | Moving the session window between a Retina and a non-Retina display keeps Actual Size 1:1. |

## Changes and verification

Implemented: the Actual Size frame-arrival refresh (`MacVideoStreamView.swift`),
the live-stream line in the quality sheet (`MacSessionControls.swift`,
`MacRemoteSessionView.swift`), and the Window Size (Adaptive/Original) submenu in
the session source menu (`MacRemoteSessionView.swift`). No shared protocol, host
trust, or input-mapping changes. Findings table rows marked "P2 (fixed)" describe
the applied changes; the others are recommendations with acceptance criteria.

Validation: `swift build` green; `xcodebuild -project MacClient.xcodeproj
-scheme MacClient -configuration Debug test` — 44 tests, zero failures.
Shipped 2026-11-17 as **Sync 4.0.0 build 83** (host: display-switch input fix,
secondary-display capture/encode codec alignment, window-resize tolerance) and
**Control 2.0.0 build 66** (client: all three fixes above), both Developer ID
signed, notarized, stapled, and wired into the Sparkle feeds and both sites.
TCC continuity verified: builds 82→83 share a byte-identical designated
requirement, so Screen Recording / Accessibility grants survive the update.
Follow-up regression report (Actual Size picture smaller than the window —
confirmed as 1:1 rendering correctly in a window that was never refit on
session start) fixed in **Control 2.0.0 build 67**: sessions that start in
Actual Size fit the window around the picture once at the first frame.
Live two-host verification (thermal-floor display, secondary focus sharpness,
60 fps experiment) remains outstanding and needs real sessions.
