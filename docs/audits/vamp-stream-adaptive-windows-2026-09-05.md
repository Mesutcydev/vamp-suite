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
