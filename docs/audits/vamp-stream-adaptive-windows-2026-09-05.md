# Vamp Stream adaptive app-window implementation — 2026-09-05

## Behavior

- Adaptive sizing preserves the pre-stream width of Codex, Cursor, Terminal, Claude, and unknown applications, bounded by the host display. Safari may narrow to 600 points or its original width, whichever is smaller.
- Layout uses the measured video viewport and retains proportional rendering. When matching the phone aspect would violate usable width, the app keeps that width and offers zoom/pan instead of compressing its layout.
- App-window orientation follows device rotation. The app picker and separate whole-display viewer retain their prior orientation policies.
- Sync debounces layout changes for 300 ms, serializes target operations, and waits out the host's existing two-second command limiter. Keyboard presentation does not request a new host aspect.
- Sync retains original window dimensions in a bounded, in-memory host cache. Original Size requests restore them subject to macOS/app/display constraints. AX resizing requires exactly one matching window; it never falls back to the focused window.
- New sizing metadata and acknowledgement are optional. Until support is acknowledged, the client omits the legacy aspect request so older Sync hosts do not perform the old narrow-window resize.
- Assistant uses its existing aspect-only resize API, drains earlier HTTP resizes, and invalidates superseded selections. Stream feedback has a fixed layout height to avoid a resize/notice feedback loop. Window rows use window identity even when multiple rows share a bundle identifier.
- Input is gated during resizing, host geometry transitions, backgrounding, lock, and decoded-video stalls. Drag locks are released on suspension. Decoder callbacks from superseded receive generations are discarded.
- Reconnect revalidates the exact application/window against the inventory and the same host fingerprint. Returning to Apps clears selection intent and refreshes the inventory; it does not quit the Mac app.

## Automated verification

- Full `swift test`: **604 tests passed**, including the final decoder callback ordering adjustment.
- Linux host tests: **24 passed** (`python3 -m unittest discover -s Tests -p 'test_linux_host.py'`); the Linux browser-chat test also passed.
- Vamp Stream simulator suite: **30 passed on iOS 26.5** after the final decoder adjustment. The same 30 tests also passed on iOS 27.0 before that adjustment.
- Release builds of **VampMiniHost, VampTerminalApp, and VampStream all passed** after the final changes.
- The sizing matrix exercises six profiles (the five requested apps plus unknown), seven viewport shapes, four host display sizes, and both orientations: 336 combinations. These are geometry tests, not visual/readability tests of the real applications.
- Regression tests cover stale/unsolicited window events, canceled selection, superseded resize requests, optional wire metadata, missing/ambiguous AX matches, host rate limiting, exact-window reconnect, drag suspension, and rotation policy.

Xcode initially failed to locate SwiftTermBuildInfoGenerator in its build cache. Rebuilding the generator from the checked-out dependency source into DerivedData resolved this without changing dependency source or tracked project files.

## Verification gaps and API limits

**The live usability acceptance criteria are not complete.** Do not interpret passing tests/builds as confirmation that each requested app is readable and comfortable on real iPhones.

- The iOS 27 simulator launched the app, but its accessibility tree was empty and automated taps did not advance the saved-host screen.
- A clean iOS 26.5 simulator exposed the onboarding controls to accessibility, but automated taps also did not advance selection. No authenticated app-window session was exercised through either simulator.
- Codex, Cursor, Terminal, Safari, and Claude still need live checks for keyboard visibility, dialogs, multi-window selection, accurate clicks, zoom/pan, movement between displays, rotation, lock/unlock, and network interruption. No app-window before/after screenshot comparison is claimed.
- No physical iPhone or iPad was used. iPad split-view coverage is numerical only.
- Vamp Assistant was not serving its control endpoint during inspection. Its API accepts an aspect ratio, not exact window dimensions or a target-window display identifier. Its recovery control is therefore labeled **Original proportions**, with explicit feedback that exact Original Size restoration requires host API support. Multi-display fitting uses conservative reported screen bounds and cannot guarantee an exact minimum width on an unknown Assistant implementation.
- The running installed host was not replaced with an unsigned build. Pairing, signing identities, Screen Recording/Accessibility grants, and terminal-session persistence were not changed.

## Remaining live acceptance run

On a trusted, updated Sync host and an available Assistant host, exercise each requested app on compact, standard, and large iPhones in portrait and landscape, and on an iPad split view. Record original/accepted bounds, capture dimensions, tap alignment, text usability, and constrained-fit feedback. Confirm that Original Size (Sync) restores the same window, that transitions release held input, that rapid rotations settle, and that reconnect never chooses a different window or the desktop. Keep any real user screenshots/logs outside the repository.

The temporary iOS 26.5 QA simulator was removed after testing. The pre-existing iOS 27 simulator was retained.

## 0.1.14 regression correction

User feedback after build 27 rejected landscape and the automatic window-choice popup. Build 28 removes all aspect-driven orientation requests and declares portrait as the sole supported orientation on iPhone and iPad, including Assistant whole-display control. A normal app tap now launches directly; explicit window choices remain under the row's long-press Windows menu.

Opening an app now preserves its Mac size by default. Sync sends Original mode without a legacy aspect hint and does not resize on viewport changes in that mode. Assistant sends no resize request until the user explicitly chooses a sizing action. Proportional rendering and local zoom/pan remain available. This supersedes the default Adaptive and device-rotation behavior described above.

Build 28 validation: 605 Swift tests passed, the iOS 27 simulator suite passed, and VampMiniHost/VampTerminalApp Release builds passed. The portrait test verifies the app delegate and the runtime orientation list; both iPhone/iPad lists in the generated source plist contain only portrait. Live Mac-window usability remains a separate verification gap.

Simulator visual check: build 28 remained portrait after both landscape rotations, and host selection/cancellation worked. Authentication required host pairing approval, so the app launcher and ChatGPT stream could not be exercised. Portrait-only iPad support declares full-screen use, so iPad split view is not supported by this configuration.

## 0.1.15: consistent viewing controls

Sync and Assistant now offer the same local Fit window and Larger text (2×) actions in Stream options. Local viewing actions release held drag input; the larger-text action enters view adjustment mode for panning. Assistant's separate resize-button row is removed, with host resizing placed in the same menu section as Sync. API-specific recovery labels remain truthful: Sync restores Original Size while Assistant can restore only Original proportions.

Zoom survives viewport/keyboard layout changes and same-window geometry updates; offsets are clamped to the current picture bounds. Selecting another Sync window resets zoom. Original Size requests are no longer canceled by unrelated viewport updates while Original mode is active.

Validation: 605 Swift tests passed, the iOS 27 simulator suite passed, and all three active Release builds passed. Authenticated live-stream interaction on both host paths is still unverified. These changes are packaged in 0.1.15/build 29.

Sizing requests now retain a newer explicit choice while an older request is in flight. Both paths use a testable latest-intent token. Assistant ignores superseded sizing replies, gates input through the debounce/queue, revalidates bounds after resize failures, and requires the capture to match the current stream configuration before interaction. The updated Swift suite passes 607 tests.

Revalidated live-test availability: Assistant is now listening, but the simulator has no saved Assistant trust and Sync still requires pairing approval. A physical iPhone is available to devicectl and has Stream 0.1.11/build25 installed; available UI automation does not expose physical iPhone control. No pairing approval, credential copying, signing changes, or physical-device installation was performed. Live ChatGPT and multi-app acceptance remain outstanding on both hosts.

## 0.1.16: Claude launcher hit area

Authenticated Sync checks confirmed ChatGPT and Claude open directly without window-choice popups, and Claude stays portrait through both landscape rotations. Claude's blank card area did not respond while its text did. Both Sync and Assistant row labels now explicitly include their entire rectangular area in hit testing.

The connected physical iPhone reports 0.1.11/build25; that historical release contains aspect-driven landscape requests. The publicly downloaded 0.1.15/build29 IPA was independently checked and declares portrait only for iPhone/iPad, with a matching checksum.

Video fails to decode in this simulator (callback -8969), while the user confirms video works on the real device. No video-pipeline changes were made based on the simulator failure. After installing the row fix without removing app data, reconnect needed host approval again, so a post-fix authenticated tap retest remains unverified. Assistant has no paired simulator workspace.


## 0.1.17: Controls help and direct picture adjustment

The shared Stream controls sheet now separates Mac gestures from picture adjustment, uses
readable cards and scalable text/icons, and keeps Done outside the scroll area. The actual
SwiftUI view was rendered and scrolled in an iPhone 17 simulator; all instructions remained
reachable above the pinned button. Both host paths present this same view.

Adjust view now accepts one-finger panning as well as two-finger panning. Its single-finger
handler routes deltas only to the viewport, with no remote pointer movement or end event.
Changing modes cancels active recognizers and scroll momentum and releases any drag lock.
The 31-test iOS 27 simulator suite passes, including incremental one-finger panning without
Mac pointer events. Stream Release rebuilt successfully; Sync and Terminal Release builds
passed after the shared help change.

The simulator browsed Mac M4's authenticated application inventory before the rebuild.
After the test build it again remained on Connecting, so no new live video/readability
verification is claimed. The prior simulator decoder limitation and missing Assistant
paired test workspace still prevent full live acceptance. No trust or TCC changes were made.

A subsequent live observation confirmed a persistent Connecting screen. The root cause was
in Stream's presentation state: `activeSessionID` is allocated before negotiation and may
remain set on error, so the root preferred its session branch and hid the actual failure.
The root now excludes error/idle phases from session presentation. The final simulator suite
passes 32 tests, including failed/idle session IDs and valid waiting/receiving states.


## 0.1.18: Quiet video startup

A two-second polled `videoStalled` Boolean could remain true after the first frame arrived,
flashing Waiting for video over healthy video and briefly disabling input. Both host paths
now derive freshness from the renderer timestamp whenever the view updates; a lightweight
timer detects actual stalls. A five-second startup grace applies to recovery feedback only,
never to the input freshness gate. Per-window/stream changes restart that grace period.

The recovery UI is a compact top overlay with a 44-point Retry target, not a floating card.
It does not change video geometry. The shared view fits large accessibility text vertically;
an isolated simulator render verified that its status and Retry button remain readable.
Normal startup retains Opening until the frame arrives, with no extra recovery popup.
34 simulator tests passed, including frame arrival between timer checks, startup with old
or missing frames, sustained interruption, and immediate recovery. Sync and Terminal Release
builds passed after the shared UI change. Live physical-device acceptance remains outstanding.

## User acceptance and installed host updates

After receiving the build 32 update and real-device check instructions, the user reported
“both are okey” for the Sync and Assistant paths. This is user-reported acceptance, not an
agent-observed live-video test. The simulator's historical decoder limitation is not treated
as a remaining product defect.

The installed Sync was updated from 2.3.0/build 64 to build 65, and Assistant from
0.10.28/build 81 to 0.10.29/build 82. Each update was signed with its existing local identity
and verified against the installed designated requirement. Read-only checks before and
after confirmed Screen Recording and Accessibility remained granted. Application data and
TCC records were not changed. Original app bundles were retained as local backups. Sync
was left running; Assistant was verified separately and closed to keep one host running.

## 0.1.19: portrait-fit default and one control deck

User feedback after the landscape add/remove cycle: portrait-only Stream must still resize
the selected Mac app to a shape that fits the iPhone screen, and the split top-bar/bottom-bar
controls must collapse into one predictable surface.

- Sync app streaming defaults to adaptive sizing again. `select` no longer resets the mode to
  Original, so the first target request already carries the viewport dimensions and modern
  hosts shape the window to the portrait viewport. Old hosts without the sizing metadata keep
  the original window because the request omits the legacy aspect hint until the host
  acknowledges sizing support.
- Assistant app streams request the adaptive portrait resize on open instead of preserving the
  original size. Original proportions remain available under Stream options.
- The bottom control deck is the single control surface for both Assistant experiences. Close,
  annotate, keyboard (with terminal focus), fit/sizing, and hide remain; the disabled
  magicmouse/terminal/audio/PiP/statistics placeholders and their divider were removed. The
  app-stream top bar keeps only Apps, title, Adjust view, Stream options, and the zoomed 1×
  reset, so the keyboard and sizing controls are no longer duplicated.
- The sizing notice is a floating overlay above the control deck instead of a layout row with a
  fixed height, so the video viewport no longer loses 36 points and notice changes cannot feed
  a resize/viewport feedback loop.

Validation: 607 Swift tests passed, the iOS 27 simulator suite passed with 34 tests, and
VampMiniHost/VampTerminalApp/VampStream Release builds passed. Live physical-device
acceptance on real apps is still outstanding.

## Host audit: 0.1.21 Stream / Sync build 67

Audit scope: the shared window-sizing policy (`AdaptiveWindowSizing`), the Sync host resize
path in `HostSessionCoordinator.beginWindowStream`, the Assistant resize contract Stream
drives (`api/control/apps/resize`, aspect-only), and the host session liveness/acceptance
path that decides whether Stream can attach at all. The Assistant host server itself is a
separate product outside this repository, so its behavior rides on the shared policy through
the aspect Stream sends.

### Correction to the 0.1.20 finding

The previous entry recorded that narrowing portrait viewports to a 600-point readable floor
made the phone screen fill. **That was wrong, and it did not fix the reported regression.**
Any width floor above `height * aspect` leaves the window wider than the viewport, and Stream
renders with an aspect-fit policy, so the picture is still letterboxed — only less severely.
Measured on the real hardware this device pair runs (a 2560x1440 Mac M4 and an iPhone 17 Pro
Max with a ~440x900 stream video area):

| policy | host window | on-phone | black bars | screen fill |
| --- | --- | --- | --- | --- |
| width floor (0.1.20) | 600x824 | 390x536 | ~364 pt | ~60% |
| aspect-exact (restored) | 439x900 | 439x900 | 0 pt | 100% |

### Root cause

`4d240a9` ("Release Vamp Stream 0.1.13 with adaptive app-window handling") replaced the
proven aspect-exact fit in `HostApplicationRegistry.targetWindowFrame` with the new
`AdaptiveWindowSizing`, whose `minimumWidth` floored the window at `original.width` (and, for
Safari only, at 600 points). The width floor — not any client rendering, orientation, or
quality-preset change — is what turned a correctly reshaped portrait column back into a wide
strip. The subsequent 600-point tweak moved the floor instead of removing it.

Findings and fixes:

- **Portrait fit restored.** `AdaptiveWindowSizing` again matches the viewport aspect exactly
  and scales that shape into the usable display, bounded by the 1400-point decoder cap. This
  is the pre-regression algorithm, so the historical complaint it was written to solve — a
  small source window staying a postage stamp the phone upscales ~3x — remains fixed, and the
  sizing matrix asserts both properties together.
- **Sizing is app-agnostic.** The Safari-only 600-point exception was the last per-app width
  special case. A regression test now asserts Safari fits exactly like every other app, and
  that aspect-fitting the result into a phone viewport leaves zero bars.
- **Measured-viewport gate hardened (client).** Extracted as a pure, unit-tested
  `AppStreamViewModel.measuredViewport`. It rejects invalid, zero, and non-finite sizes (the
  first layout pass reports `.zero`), keeps the container's width/height ordering untouched so
  a portrait measurement cannot become a landscape request, and coalesces sub-2-point layout
  noise so keyboard animations and control overlays cannot drive a resize loop.
- **Wire fields made explicit (client).** `AppStreamViewModel.sizingRequestFields` emits width
  and height in measured order — never sorted or min/max'd — and keeps withholding the legacy
  `clientViewportAspect` hint until the host acknowledges sizing support, so an older Sync
  leaves the window at its original size.
- **Assistant fallback corrected.** When the Assistant host reports no usable display bounds,
  Stream previously requested `max(viewportAspect, originalAspect)`, which preserved a
  landscape window's landscape shape — the exact strip this resize exists to avoid. It now
  requests the phone's aspect.
- **Resize feedback compares against the request, not the raw viewport.** With an aspect-exact
  fit the two normally agree, so the "different window shape" notice now only appears when the
  Mac genuinely could not honor the request.
- **Dead sessions no longer hold the host (Sync connectivity).** The client-liveness watchdog
  required a non-nil last-activity stamp, so a session whose data channel never opened was
  never reclaimed: a half-open transport still reported `.connected`, capture/encode kept
  running for nobody, and the retained `activeSessionID` made the host reject every real client
  as "already connected to another device" until the process was quit. This was observed live —
  the installed Sync had been encoding 2560x1440 for over two hours with **zero** established
  sockets. Silence is now measured from session start; extracted as a pure, unit-tested
  `HostClientLiveness` rule.
- **Connection budget sized to the real reconnect sweep.** Sync allowed 5 signaling connections
  per IP per minute. A client sweep can legitimately spend far more (up to three
  `reconnectLast` attempts across several LAN/Tailscale candidates, each possibly opening a TLS
  and a plaintext socket). Reproduced live: the 6th connection was refused at TCP accept, which
  is unrecoverable because nothing sent afterwards can be read on an unaccepted socket. The
  budget is now 30 per minute.
- **Budget clearing gated on trust, not on signature.** Clearing a peer's budget previously fired
  for any message that merely passed signature verification. A signature only proves the sender
  owns the key it signed with, and anyone can generate a keypair — so an unauthenticated peer
  could erase its own flood budget indefinitely and defeat the limiter. Only fingerprints the
  trust gate has actually approved now clear their budget (`noteTrustedPeer`), wired in at the
  point `evaluateAndPrompt` returns trusted.

Verified unchanged: original-bounds restore, invalid-viewport passthrough, unique AX bounds
matching (never the focused window or the app's first window), the 350 ms post-resize re-read,
the two-consecutive-miss window-loss rule, capture/encoder restart on accepted geometry, and
touch mapping through the accepted window descriptor.

Validation: 626 Swift tests passed (up from 609; new coverage for aspect-exactness, display
fill, app-agnostic sizing, viewport rejection/coalescing, wire-field ordering, the legacy-hint
gate, the liveness rule, the reconnect budget, and trust-gated budget clearing). The 34-test
iOS 27 simulator suite passed. The 24 Linux host tests passed. Release builds passed for
VampMiniHost, VampTerminalApp, VampStream, and the legacy MacHost/VampTerminalHost shared-source
verification targets. The full chain was also recomputed against the real 2560x1440 / 440x900
geometry for six representative apps: every one now yields 0 pt of bars and 100% screen fill.

Live physical-device acceptance on real apps remains outstanding and is not claimed from these
builds and tests alone.

