# Changelog

All notable changes to Vamp Suite are documented here. Historical MacPair entries retain
their original product names. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed: every app target in the repository can be built again

- **No iOS target in this repository built.** SwiftTerm 1.19.0 added a SwiftPM build-tool plugin
  whose `SwiftTermBuildInfoGenerator` is a macOS host executable; for an iOS destination Xcode
  looks for it in `Build/Products/Debug` while only `Debug-iphonesimulator` is produced, so every
  iOS build failed with `Build input file cannot be found`. All specs are pinned to 1.18.0, the
  last release without that plugin. Vamp Stream drops the dependency entirely — its only importer
  was Terminal Mode, which Stream never mounts.
- **Vamp Sync could not be built at all.** Its whole implementation lives behind
  `#if VAMP_MINI_HOST`, and no spec defined that flag, so the product was compiled out of every
  target; `xcodebuild -scheme VampMiniHost` — the command in AGENTS.md and in CI — failed with
  "does not contain a scheme named VampMiniHost". The Info.plist and entitlements were still in
  `Configuration/`; only the target was missing. Same for `VampTerminalHost` and `VampTerminalApp`.
  All three targets and schemes are restored, so the documented build set and the CI workflow now
  match what the project actually contains.
- **Three targets imported products they never declared** — `iOSRemoteApp` imported `SharedUI`,
  and both Mac hosts imported `HostWidgetShared` and `SharedUI`. Each failed at dependency
  scanning; on iOS the failure was hidden behind the earlier SwiftTerm one.
- `iOSRemoteApp` compiled Vamp Terminal's views, which reference `VampTerminalDesign` from a
  module it does not link. `vampstream-project.yml` already excluded exactly that file set with a
  comment claiming it "matches the iOSRemoteApp file set" — iOSRemoteApp had no such list.

### Changed: Vamp Stream carries only the code it runs

- Vamp Stream compiled Vamp Control's entire tab UI (`Views/`) and first-run flow (`Onboarding/`)
  — about 6,000 lines it can never display, since it has its own root and its own onboarding.
  Both are excluded, which is also what lets the SwiftTerm dependency go.
- Removed the unreachable whole-display Remote Control destination. Its only entry point was
  inside a dead view, while `AssistantExperience` still *defaulted* to it — the same trap that
  previously sent a freshly paired Mac to the whole desktop instead of the app browser. Vamp
  Stream is the app-window client; whole-desktop control is Vamp Control's job. The Assistant
  surface still falls back to `BeetCodeRemoteView` for the locked and permission states.
- Deleted ~250 lines of unreachable views from `VampStreamConnectView` and the unused
  load/save wrappers around `@AppStorage` keys. Their tests now assert the contract the app
  actually depends on — the key names and the fallback behaviour — instead of wrappers nothing
  called.

### Fixed: the two stream surfaces stop drifting apart

- **The Assistant path drew a hand-written copy of the shared control deck**, which the shared
  component's own documentation warns is "how the Sync path and the Assistant path drift into
  looking like different apps". They had: a different hide/reveal button, a different reset
  control, different tap targets. Both paths now draw `AppStreamChromePill`. The height the
  picture reserves for the deck also moved onto that component, so the deck and the space left
  for it can no longer disagree.
- The gesture help — shown automatically on a user's first ever stream — told them to "Choose Fit
  window" from a menu that had no such item on the Sync path. Both menus now offer the same two
  picture actions, and the help describes what is actually there.
- The same action had two names ("Original Size" / "Original proportions") and picture quality had
  two different mental models ("Quality" presets vs "Resolution" in pixels). Both are now
  "Picture quality", named for the outcome, with the resolution kept as secondary detail on the
  Assistant path so nothing is lost. The Sync picker's "Auto" named a mechanism that preset does
  not have — it maps to the fixed balanced preset — and is now "Balanced".
- Favourites and recents, Bluetooth mouse and keyboard, the first-run gesture help, and a manual
  "Refresh video" existed only on the Sync path. All four now work on both, and favourites are
  shared: both browsers key on the bundle identifier, so a starred app stays starred whichever
  kind of Mac it is on.

### Fixed: touch targets, splash, and design tokens in Vamp Stream

- **The bottom control deck was 30 pt tall** — under the 44 pt minimum, floating over video with
  nothing forgiving around it, so near-misses landed on the streamed Mac instead. The reveal
  button that is the only way back from hidden controls was 32×32. The keyboard deck was worse:
  every modifier, key, shortcut and header chip sat between 26 and 33 pt. All are 44 pt now, with
  the glyphs kept small.
- **The splash could not be skipped** and cost 1.7 s on every cold launch — it already swallowed
  taps, it just did nothing with them. A tap now dismisses it. Reduce Motion used to remove the
  moving pieces but keep the full wait, which is the opposite of what the setting asks for; it now
  shows the finished artwork and leaves almost immediately. `SplashTiming` listed marks the code
  did not use and had drifted from it (the portal was declared at 450 ms and appeared at 370 ms);
  the schedule is now what the animation actually follows.
- **`PR.r12` was 16**, so a view that wanted 12 points could not use the token and hardcoded the
  literal instead — which is how this tree accumulated nine different raw corner radii beside a
  design system that already had a scale. It is `PR.rCard`, and Vamp Stream's 28 remaining raw
  radii are tokens.
- The keyboard deck was lowercase monospace ("keyboard", "hide kb", "type and send") inside an app
  that is otherwise sentence-case SF Pro, and the gesture help rendered in stock grouped-Settings
  colours on top of a black custom UI. Both now use the app's own type and surfaces. Modifier keys
  show the Mac's real glyphs (⌘ ⇧ ⌥ ⌃) with spoken names for VoiceOver, and shortcut chips name
  what they do instead of running glyph and label together ("⌘⇧3 shot").

### Added: Vamp Stream pointer input reaches Vamp Control parity

- **A paired Bluetooth mouse barely worked in Stream.** `BluetoothInputController` was bound to
  Vamp Control's view model, so Stream could not use it at all: the hover cursor moved, but the
  left/right/middle buttons and the scroll wheel went nowhere, a physical keyboard produced
  nothing, and there was no sensitivity control. The bridge is now a shared
  `RemotePointerInputSink` protocol that both clients implement, so one implementation serves
  both apps. Stream observes paired devices for the session and exposes the same status sheet with
  mouse and scroll sensitivity sliders.
- **Stream had no haptics at all,** so a click that landed on the Mac felt identical to a swipe
  that did not. It now uses Vamp Control's exact impact styles: light for single, two-, and
  three-finger taps, medium for double-tap, soft and rigid for drag-lock release and engage.
- The velocity-acceleration curve was inlined three times with the same magic constants (Control,
  Stream's Sync path, and Stream's Assistant path), which is how a paired mouse drifts into
  feeling different per app. It is now one shared `PointerDynamics` helper, so the three paths are
  identical by construction rather than by coincidence.

### Fixed: one control deck and a portrait Mac window on the Sync path

- **Streaming an app from Vamp Sync had no bottom control deck.** The Assistant path drew the
  bottom pill (close, annotate, keyboard, window sizing, fit, hide) while the Sync path kept a
  crowded top bar with its own keyboard button and a hidden ••• menu — the two host paths read as
  different apps, and the controls people reach for mid-stream were missing. The deck is now one
  shared component (`AppStreamChromePill`) that the Sync path draws too, with the top bar reduced
  to navigation and the stream-options menu so no control is repeated.
- **A Mac window could stay landscape on a portrait phone.** The client only asserted the phone's
  shape once the host had already acknowledged adaptive sizing, so a stream that began before the
  video surface reported its size left the window at its original shape and the phone rendered it
  letterboxed. After the host proves it supports adaptive sizing, the client now compares the
  returned window's aspect against the device viewport and re-asserts the measured shape once per
  window — it never loops on a Mac that legitimately keeps a different shape, and never overrides
  an explicit Original Size choice.
- Vamp Stream updated to 0.1.22/build 43.

### Fixed: the streamed pointer could wedge the UI in an update loop

- **A cursorless stream could freeze the app at ~100% CPU instead of drawing.** The local pointer
  model assigns its `@Published` position in `setSurface`, and the mirror/control surfaces call
  that from inside a `GeometryReader` view builder. Publishing during a view update re-runs the
  body, the body calls `setSurface` again, and the loop never settles — the control screen looked
  frozen and never answered a tap. `setSurface` now compares before assigning (an `@Published`
  setter has no equality check of its own), and Vamp Assistant's control surface places the cursor
  from a lifecycle hook rather than the builder.
- Vamp Stream updated to 0.1.22/build 44.

### Fixed: the Mac window actually takes the phone's shape, at the phone's resolution

- **The resize was applied in the wrong order, so macOS clamped it.** `HostSessionCoordinator`
  asked AX for the new window *size* first and moved the window afterwards. AppKit constrains a
  window's frame to the screen when its size is applied, so a window sitting low on the display
  had its height silently cut: the host then honestly reported "The Mac kept a different window
  shape", and the capture stayed small enough that the phone upscaled it — the soft, letterboxed
  picture behind both reported symptoms. The window is now anchored inside the usable area first,
  the size is applied second, the size is re-asserted once for apps whose AX set lands before the
  move settles, and one bounded retry re-anchors from the *accepted* bounds. The retry decision
  and the user-visible notice share one pure `aspectMismatch` rule, so "we retried" and "we told
  the user" can never disagree.
- **A window the Mac could not reshape cannot be fixed locally, so the local picture modes are
  gone.** The Sync deck had grown four sizing-looking controls — Mac window sizing, Fit Display /
  Fill Screen, a fit-window reset, and a Fill screen remedy on the notice — and none of them
  changed the outcome: they crop or zoom a window the Mac had already declined to reshape, which
  leaves the geometry the user was actually complaining about untouched. The deck now exposes
  exactly two window-sizing choices, **Adaptive resize** and **Original Size**, and the picture is
  always aspect-fit. The real fix is the host-side resize above.
- **Window captures are clamped to what the pair can actually decode.** `ultra` passed the
  source's native pixels straight through, so a window on a 5K/6K display could build a frame
  past the client's hardware decoder (H.264 level 5.2 is 4096×2304; the M4 media engine encodes
  H.264/HEVC to 4K60). Window streams are now capped at the shared 4K UHD envelope
  (3840 px long edge, 8.29 MP, even axes, aspect preserved, shrink-only). Display streams are
  untouched. The window long-edge cap also moves 1400 → 1440 points: at 2x that is 2880 px, just
  over an iPhone 17 Pro Max's 2868 px native screen, where the old cap produced 2800 px and made
  the phone upscale by 2.4%.
- **The control deck no longer sits on top of the streamed app.** The deck floats over the
  bottom of the video surface, so the picture was drawn underneath it: the streamed app's own
  bottom controls (a send button, a toolbar) landed under the deck's eye and hide controls, and
  the Mac was asked to match an area taller than the phone could actually show — which is what
  left a black band above the picture. The surface now reserves the deck's band, the picture is
  drawn at exactly its fitted size and pinned to the **top**, and the input mapper is given that
  same rect so touches still land where they are drawn. Any letterbox slack now falls below the
  picture, behind the deck, instead of above it.
- **A few percent of shape shortfall no longer shows as a black gap.** A Mac app can decline the
  exact shape it was asked for by a small margin — an app minimum, or a screen whose visible frame
  is shorter than its bounds — and even the fixed host can land a few percent short. That residue
  is now absorbed by scaling the picture so its **height matches the surface exactly**: the gap
  above the control deck disappears, and because nothing is lost vertically the streamed app's own
  bottom controls keep their place. The small overflow crop falls on the left and right edges
  (~3% split across them). The input mapper and the cursor overlay follow the same rect, so touches
  and the local pointer stay exact. A shortfall larger than 12% still
  letterboxes honestly rather than cropping most of the picture away.
- **The stream keyboard deck no longer appears and then vanishes.** The deck was positioned
  twice: the surface ignored the keyboard safe area *and* a UIKit keyboard-inset observer pushed
  it up by the keyboard's height, so the panel ended up above the top of the screen. The surface
  now ignores only the container's bottom inset, iOS places the deck directly above the system
  keyboard once, and the manual inset observer is gone along with its dead view. The deck's
  optional rows (quick actions, shortcuts, helper text) degrade through `ViewThatFits` so it
  always fits the space above the keyboard, while the header and composer keep a stable identity
  so the text field never loses first responder mid-sentence. The Assistant app-stream surface had
  the same double shift and got the same fix.
- Vamp Stream updated to 0.1.22/build 47. The resize fix is host-side, so it needs the matching
  Vamp Sync build as well: an older installed Sync (build 68) keeps clamping the window height,
  which is why the notice and the top letterbox bar survive a client-only update.
- Vamp Sync host updated to 2.3.0/build 69.

### Changed: the streamed pointer glyph is black, not white

- **The local pointer disappeared into bright Mac content.** Over a cursorless stream Stream (and
  Vamp Control, which shares the overlay) draws the pointer itself, and a solid white body washed
  out against documents and light app chrome. The glyph is now a solid black body with a hairline
  white outline and the same soft shadow: black reads as the pointer on light content, while the
  outline keeps it findable on dark terminals and dark-mode apps. Vamp Assistant's iOS app draws
  the same glyph.

### Changed: calmer, hosts-first connect home

- **Hosts are the primary content.** The home used to lead with two always-expanded pairing forms,
  so a returning user scrolled past setup they had already finished to reach their Macs. Configured
  Macs now come first, above a "Pair a host" divider, with both pairing cards collapsing to compact
  headers and the version string moved to a subdued footer instead of the page title.
- Both pairing cards share one reusable shell: the whole header is a single disclosure button with
  the chevron as part of its label, and collapsed means header only — the body leaves layout and the
  accessibility tree rather than hiding behind opacity. Each provider persists independently, and the
  first-run default is latched once so a host briefly dropping off the network cannot flip the cards
  open again.
- Rows and forms sit on quiet opaque content surfaces with hairline borders instead of per-row glass,
  which made every app look like an equally important floating control. The light-scheme wallpaper
  scrim was 0.04 — bright enough for artwork to wash out row labels — and is now a real scrim.
- The app pickers for both providers share one section surface, heading style, header metrics, and
  search-field inset, so they no longer look like separate mini-apps. App icons are fitted rather
  than stretched, window titles replace raw pixel dimensions in lists, and the "Installed · tap to
  open" narration is gone from every installed row.

### Fixed: app-list icons publish at the resolution the row renders

- **The Stream app list looked low-resolution.** The browser draws every icon inside a fixed
  42 pt row, so a 3x phone samples it into 126 device pixels — and the hosts were serving tiles
  well below that (Vamp Sync 32 px, Vamp Assistant 48 px), which the row then upscaled. Both
  hosts now publish a 192 px tile: ~1.5x headroom over the 3x row, and the largest tile the
  transport can still carry. The list is paginated under a 112 KB per-page budget inside the
  control channel's 128 KB per-message cap, and an icon that cannot fit a page is silently
  dropped to a placeholder row — measured over a full `/Applications`, 192 px keeps every real
  icon inside one page (~80 KB base64 worst case), while 256 px pushes the heaviest ones
  (Xcode ≈ 138 KB) past the budget and costs that app its icon entirely.
- Vamp Sync host updated to build 68.

### Fixed: a busy Mac no longer disables the whole home

- A Vamp Sync host-busy rejection was merged into the Assistant error slot
  (`assistant ?? coordinator`), so a Vamp Sync problem rendered as a **Vamp Assistant** problem and
  as an unrelated page-wide card between provider sections. Errors now route to their own provider,
  and "Mac is in use" is scoped to the single Mac that refused — the others stay usable.

### Fixed: portrait app-window fit restored on both host paths

- **Vamp Stream letterboxed Mac apps again.** The shared adaptive window policy had replaced the
  aspect-exact fit with a width floor (first the window's original width, then a 600-point
  "readable" floor), so a 1100×700 editor on a 1440×900 Mac became a 600×824 window. That is
  wider than an iPhone's portrait aspect, and an aspect-fit renderer shrank it into a strip with
  black bars above and below — about 61% of the screen. `AdaptiveWindowSizing` now matches the
  viewport aspect exactly and scales that shape into the host display, bounded by the 1400-point
  decoder cap, so the same editor becomes a tall, narrow 380×824 column and the phone renders it
  edge-to-edge with no bars.
- Sizing is app-agnostic again. The Safari-only 600-point exception was the last per-app width
  special case, and any width floor above `height × aspect` reintroduces the letterbox bars.
- Landscape viewports still keep their own aspect; a portrait measurement can never be reordered
  into a landscape request. Stream's measured-viewport gate now rejects invalid, zero, and
  non-finite sizes and coalesces sub-2-point layout noise, so keyboard animations and control
  overlays cannot drive a Mac window-resize loop.
- The legacy `clientViewportAspect` hint is still withheld until the host acknowledges sizing
  support, so an older Vamp Sync keeps the window at its original size rather than performing the
  historical narrow-window resize.
- Vamp Sync resize feedback compares the accepted window shape against the requested shape, and
  Assistant compares against the expected size from the same shared policy, so the "different
  window shape" notice only appears when the Mac genuinely could not honor the request instead of
  on every portrait fit.
- Vamp Assistant streams whose host reports no usable display bounds now still ask for the phone's
  aspect. The previous fallback took `max(viewportAspect, originalAspect)`, which kept a landscape
  Mac window landscape — the exact strip this resize exists to avoid.
- The host now logs one consolidated sizing line per resize: measured viewport, resolved target,
  requested and accepted bounds, and whether the resize applied. Geometry numbers only — never
  window titles or content.

### Fixed: Vamp Stream could not reconnect to Vamp Sync

- **A dead session held the host forever.** The client-liveness watchdog required a non-nil
  last-activity stamp, so a session whose data channel never opened was never reclaimed. A
  half-open transport still reported `.connected`, capture and encode kept running for nobody, and
  the retained `activeSessionID` made the host answer every real client with "already connected to
  another device" until the host process was quit. Silence is now measured from session start, so
  a session that receives no traffic within the timeout is torn down. Extracted as a pure,
  unit-tested `HostClientLiveness` rule.
- **The connection budget was too tight for a legitimate reconnect.** Vamp Sync allowed 5 signaling
  connections per IP per minute, but a client reconnect sweep can spend far more: up to three
  `reconnectLast` attempts across several candidate endpoints (LAN and Tailscale), each possibly
  opening a TLS socket and a plaintext one. Once exhausted, every later attempt was refused at TCP
  accept — before the client could send anything identifying it as trusted — which is an
  unrecoverable lockout rather than rate limiting. The budget is now 30 per minute.
- Clearing a peer's connection budget is gated on actual trust approval. It previously fired on any
  message that merely passed signature verification, but a signature only proves the sender owns
  the key it signed with — anyone can generate a keypair. Only fingerprints the trust gate has
  approved now clear their budget.
- Vamp Sync host updated to build 67; Vamp Stream updated to 0.1.21/build 35.

### Stream portrait fit and controls

- Selected Mac apps resize to a portrait shape that fits iPhone screens again. Vamp Sync keeps the adaptive sizing mode across selections and Assistant app streams request the portrait-fit resize as soon as the app opens.
- Stream keeps one control deck: the bottom bar owns close, annotate, keyboard, fit/sizing, and hide controls, dead placeholder buttons are gone, and the app-stream top bar no longer repeats them.
- Stream sizing notices float over the video instead of reserving a permanent strip, so the picture keeps its full viewport.

### Stream stability follow-up

- Restore installed-app icons by paging inventories before removing icon data.
- Keep scrolling directed to the Mac at every zoom level. Use Adjust view to intentionally pinch or pan the picture.
- Release long-press dragging when the finger lifts or the gesture is canceled.


### Fixed

- Vamp Stream preserves input order under backpressure and disconnects on delivery failure. Sync releases held input when an attachment ends and immediately invalidates access when a connected device is revoked.
- Correlated, cancelable app launches prevent stale results from replacing a newer selection. Large app inventories use bounded pages. QR scanning failures now offer recovery and source-specific connection instructions.
- Remote keyboard positioning uses the current view's keyboard layout guide. Assistant window selection rejects stale asynchronous results.

### Added

- Stream app search, favorites, recents, window selection, saved quality choices, gesture help, drag release and video recovery controls.
- A visible Sync connection entry and manual address connection, plus standalone Stream Release CI coverage.

### Changed

- Vamp Stream asks which Mac host you use (Vamp Sync, Vamp Assistant, or both) and builds the connect home from that choice.
- The Stream connect home keeps a quiet live atmosphere behind the glass.
- Stream offers a dismissible Vamp Sync card that opens the Sync download page. Confirming Sync is installed hides the card.
- After a Sync host is paired, the connect card can be minimized from the corner so the home list stays primary.
- Vamp Sync and Vamp Stream use the window-and-fangs mark for the Sync tray, Sync panel, and Stream app icon.
- Stream’s connect home can switch Macs to a Control-style rectangular card grid.
- Stream’s app lists, pairing, and empty states use the same glass controls and title scale as the connect home.
- Stream can quit a running Mac app from the app list or the live stream menu. Sync asks the app to quit and never force-kills it.
- Update SwiftTerm to 1.20.0 and vendored Opus to 1.6.1, with updated provenance and SBOM metadata.
- Cache app icons, use lazy browser sections, respect system appearance in the Assistant browser and reduce routine stream logging.

## [2.3.0] - 2026-09-03 — build 58

### Fixed

- Vamp Control macOS now extends immediate local-cursor feedback and bounded
  pointer delivery to Vamp Assistant sessions. Updated Assistant hosts omit the
  captured cursor only when the Mac client requests it; iOS clients keep the
  remote cursor in their video.

## [2.3.0] - 2026-09-03 — build 57

### Fixed

- Vamp Control macOS now shows the native local cursor during compatible Mac
  sessions, removing video round-trip delay from pointer feedback. Pointer moves
  and scroll updates are coalesced while the input channel is busy so stale
  motion cannot build up and replay later.
- Vamp Sync negotiates cursorless capture with the updated macOS client. Older
  clients keep the prior captured-cursor behavior for wire compatibility.

## [2.3.0] - 2026-09-03 — build 56

### Fixed

- Vamp Sync remote unlock now wakes and clears the macOS login field before
  entering the submitted password. It posts paced physical HID keys resolved
  through the Mac's active keyboard layout, and stops immediately if the Mac
  unlocks locally or Accessibility permission is lost.
- Vamp Stream now receives the Mac's initial locked/login-window state in the
  reliable session-ready handshake instead of depending on a best-effort early
  data-channel update. Connecting to an already locked Vamp Sync or Vamp Host
  now opens the password-entry unlock screen consistently.
- Older Stream and host builds remain wire-compatible: the new handshake field
  is optional, and live lock/unlock transitions still use authenticated host
  status messages.

## [2.3.0] - 2026-08-31 — build 52

### Fixed

- Vamp Sync now honors the Quality or Ultra resolution requested by Vamp Stream
  instead of treating its idle Balanced profile as a permanent 1080p ceiling.
  Low Power Mode, thermal pressure, and adaptive network quality can still reduce
  the stream safely when needed.
- Vamp Stream 0.1.3 defaults Vamp Sync sessions to the sharpest preset supported
  by the iPhone or iPad and upgrades the historical Vamp Assistant 1080p default
  to its native-resolution stream profile.

## [2.3.0] - 2026-08-31 — build 51

### Fixed

- Vamp Stream now presents the authenticated Mac-password unlock form whenever
  Vamp Assistant reaches the lock or login window, allowing app streaming to
  resume without a local unlock.
- Vamp Sync now exposes its Remote Unlock permission in the companion access
  card and uses the same host-side policy as Vamp Host.

### Added

- Vamp Stream displays its marketing version and build number on the Mac picker
  so installed AltStore builds can be identified directly inside the app.

## [2.3.0] - 2026-08-30 — build 50

### Security

- Pairing codes for Safari/Linux browser control are 12 digits. The QR carries
  only the host URL; the code is typed on a trusted screen and is no longer
  accepted from `?pair=`.
- Session answers no longer echo the control-channel token on signaling.
  TLS signaling on 9473 retries three times; plaintext 9471 stays up if TLS
  fails so a first-time typed address can still connect.
- macOS headless agent launchers no longer pass provider yolo / skip-permissions
  flags. Interactive approvals stay in Terminal, matching Linux.
- Remote login-window unlock defaults to off.
- `vamp approve-pairing` writes a fingerprint-bound local trust file instead of
  putting the fingerprint on `vamphost://`. URL-scheme approve links cannot
  complete pairing by themselves.
- A known peer that presents a new identity key is rejected as a possible MITM
  instead of a casual Allow prompt. Forget the old device to re-pair.
- Control-channel pings require the same HMAC as other envelopes.
- Linux refuses wildcard binds (`0.0.0.0` / `::`) even with `--allow-non-loopback`.

### Added

- Vamp Mini Host, a separate macOS menu-bar app with its own host identity and
  trusted-peer store. It provides pairing review, exact fingerprint confirmation,
  permission guidance, Tailscale status, and Start / Stop / Restart controls.
- A standalone [Vamp Mini Host product page](docs/mini-host/index.html) and a
  dedicated `VampMiniHost` packaging target.
- Unified Chat and Terminal launcher support across Vamp Host, Vamp Terminal Host,
  Vamp Terminal iOS, and the Linux browser host for OpenCode, Pi, CommandCode,
  ChatGPT/Codex, Claude, Kimi, Qwen, Codex, Aider, Grok, and Gemini.
- Provider-native semantic adapters for Kimi, Qwen, Aider, and Gemini, including
  resumable session IDs where each CLI exposes them. Linux runners keep provider
  approval and sandbox modes safe; use Terminal for interactive approvals.

### Fixed

- Vamp Sync now follows the app-only Vamp Assistant streaming lifecycle: it
  establishes the authenticated control channel before capture, starts video
  only after an application window is selected, and refuses full-display
  targets.
- Vamp Sync uses one unified status, pairing, permission, and trusted-device
  surface instead of overlapping tab and stream-state dashboards.
- Application launch, shareable-window validation, window fitting, and capture
  recovery keep the selected app visible without falling back to a display.
- Vamp Stream's app list now reaches the phone on Macs with a large
  `/Applications`. The icon-rich snapshot exceeded the control channel's 128 KB
  message limit and was dropped in transit; icons are now shed until it fits.
- Vamp Stream no longer streams the whole Mac desktop when the host resolves no
  window for a selected app — it stays in the browser and says so.
- Launching an app through Vamp Assistant waits 60s instead of 15s, so a cold
  start of a heavy app no longer reports a timeout while the Mac is still
  opening it.
- Agents and background-only bundles are excluded from the app browser; they can
  never open a streamable window.
- Fit-to-phone resizes the window that is actually being streamed instead of the
  app's focused window, and the "open a window" Cmd+N goes to the target process
  rather than the global event tap.
- Pairing a new Vamp Assistant Mac opens the app browser. It previously dropped
  into the whole-desktop Remote Control surface, which this build does not offer.
- The Assistant stream sets the phone orientation from the window the Mac
  actually sent, so a landscape window is no longer letterboxed into a thin strip
  on a portrait-locked screen.
- Keyboard shortcuts (⌘C, ⌘V, ⌘Z, ⌃C, ⌃L, ⌘⇧3 …) reach the Mac over Vamp
  Assistant. They were sent as unnamed key codes and silently discarded.
- Saved Assistant Macs are probed in parallel with a short timeout, so one
  offline Mac no longer stalls the whole list on "Checking".
- Window fitting grows a small window into the display instead of only
  shrinking it. Terminal's default window was narrowed to roughly 172x374
  points — about 31 columns — which the phone then upscaled nearly 3x into
  unreadably large text. Capped so the capture stays within what a phone can
  decode.
- The streamed window is fitted to the area the video actually occupies rather
  than the enclosing safe-area frame, removing a permanent letterbox band.
- Resizing a streamed window on the Mac restarts capture once the drag settles
  instead of on every 200 ms poll.

## [2.3.0] - 2026-08-22 — build 47

### Fixed

- Vamp Control on macOS now derives its signaling peer ID from its persistent
  public-key fingerprint. Relaunching the client no longer makes the same Mac
  appear to be a second device during the host's disconnect grace period.
- Vamp Host permits a fast transport replacement when the incoming client has
  the exact same valid cryptographic fingerprint, while continuing to reject a
  different device from evicting the active session.
- macOS reconnect attempts now wait for the replacement transport to reach the
  connected state instead of treating an SDP answer as a completed recovery.
- Ultra sessions now remain on the deterministic SDR color path unless HDR is
  explicitly enabled, fixing washed-out or veiled remote desktop colors.
- Vamp Host installs and loads its per-user watchdog automatically on first
  launch. Watchdog-requested termination no longer creates the intentional-Quit
  pause marker that previously prevented relaunch.

## [2.3.0] - 2026-08-22 — build 46

### Added

- Vamp Host can publish a main-run-loop heartbeat to an optional per-user
  watchdog that relaunches a crashed or unresponsive host while respecting an
  intentional Quit.
- Vamp Control on iPhone and iPad supports system Picture in Picture for a
  view-only floating remote session.
- Vamp Control on iOS and macOS includes an explicit command for sending
  Command-Tab to the remote Mac.

### Changed

- Apple Silicon hosts request VideoToolbox's hardware encoder and low-latency
  rate control, with at most one frame of encoder delay.
- iPhone zooming stays anchored under the fingers, clamps against the fitted
  remote display, and coordinates pinch and pan without accidental scrolling.
- Vamp Control macOS uses build 46 so both remote-control clients match the
  current suite release.

## [2.3.0] - 2026-08-22 — build 45

### Fixed

- Chat no longer stays agent-busy after a provider finishes a turn. OpenCode
  runs as a one-shot JSON process, prompts are passed after `--`, and leftover
  provider processes are stopped so the host slot is released.
- Typed Tailscale and MagicDNS addresses reuse a previously paired TLS
  fingerprint and sealing key instead of falling back to cleartext signaling.
- Host pairing UI shows the full fingerprint for out-of-band comparison.
- Safari control names the process occupying port 9475 and offers Retry.

## [2.3.6] - 2026-08-22 — Linux Host

### Fixed

- Claude, OpenCode, and Codex prompts are passed after `--` so a prompt that
  looks like a flag is not parsed as one.

### Security

- Rotating the pairing code revokes existing browser tokens. Paired tokens now
  expire after 30 minutes.
- Pairing and WebSocket upgrades require a same-origin `Origin` header.
- Binding `--listen` off loopback now requires `--allow-non-loopback`.

## [2.3.5] - 2026-08-22 — Linux Host

### Fixed

- Background services now discover provider launchers and their Node runtime
  in common OpenCode, NVM, asdf, mise, pnpm, Deno, Bun, Volta, npm, Cargo, and
  user-local install directories.

## [2.3.4] - 2026-08-22 — Linux Host

### Added

- Linux browser Chat now supports Codex CLI, OpenCode, and Gemini CLI in
  addition to Claude Code, using each provider's machine-readable headless
  output and resumable session identifier.
- Selecting `claude`, `codex`, `opencode`, or `gemini` in a new Chat tab routes
  subsequent prompts to that provider without scraping its interactive TUI.

### Security

- Linux provider runners do not add unsafe permission, sandbox, or approval
  bypass flags. Interactive approval flows remain available in Terminal.

## [2.3.3] - 2026-08-22 — Linux Host

### Added

- Linux browser Chat can launch Claude Code by entering `claude`, then routes
  subsequent messages through Claude's documented non-interactive
  `stream-json` interface.
- Claude replies stream as provider-native semantic events and preserve their
  session ID for follow-up messages without scraping the interactive TUI.

## [2.3.2] - 2026-08-22 — Linux Host

### Fixed

- Linux browser pairing now survives refreshes for the lifetime of the paired
  browser token, and transient WebSocket disconnects no longer erase it.

## [2.3.1] - 2026-08-22 — Linux Host

### Added

- Linux browser control now includes per-tab Chat and Terminal presentations.
- Linux Chat renders exact composer submissions with bounded, command-scoped
  output while keeping startup noise and terminal control sequences out of the
  conversation surface.

### Changed

- The Linux host now advertises command-scoped Chat support. Provider-native
  agent events and structured task plans remain unsupported.

## [2.3.0] - 2026-08-17 — build 44

### Added

- Vamp Terminal iOS: agent replies render Markdown — inline emphasis, links,
  headings, and lists — with copyable code cards, tables, and a live streaming
  caret.
- Long-press "Copy message" on any chat block.
- Browser task chat: inline emphasis and links, a Copy button on code blocks,
  and a live streaming caret.

### Changed

- Vamp Terminal iOS: the reconnect banner offers "Retry now" and distinguishes
  "Waiting for network" from "Reconnecting to Mac"; connection errors are shown
  in plain language with a next step.

### Fixed

- Vamp Terminal iOS: agent chat text now uses the adaptive label color instead
  of the dark terminal's cream, so agent replies are legible in the light
  appearance (they were previously near-invisible).
- Vamp Terminal iOS: chat output no longer traps scrolling in a nested region.
- Browser control: the clipboard popover actions stack cleanly instead of
  overlapping.
- Linux companion host is branded "Lite" to state its terminal-only scope.

## [2.3.0] - 2026-08-17

### Added

- Live "Working" status in the Vamp Terminal workspace and the browser task
  chat: any tab with a streaming agent block counts as working, and the header
  shows a running "Working for Xm" timer while activity continues.
- Vamp Terminal iOS now defaults to the light appearance.

### Changed

- Light theme across the browser-control surfaces: the embedded task chat
  (host browser control) and the Linux host UI are now clean light-mode
  interfaces with white panels, zinc borders, and ink accents.
- Vamp Terminal iOS workspace controls use solid ink buttons with white text
  instead of translucent glass, with a stronger selected-mode outline and
  refined raised surfaces.
- Unified suite versioning: Vamp Host, Vamp Terminal Host, Vamp Terminal
  (iOS), Vamp Control (iOS + macOS), and the Linux companion now all report
  **2.3.0 (build 43)** so the family reads as one release line.
- New app icons across the suite: Vamp Host, Vamp Terminal Host, Vamp
  Terminal (iOS), and Vamp Control (iOS + macOS).
- New brand wallpaper behind the glass surfaces of both iOS apps.

### Fixed

- Vamp Control iOS: color palette selection now repaints the whole app
  immediately. The accent was a cached static color that never followed the
  runtime tint; it now resolves fresh from a published palette manager.
- Vamp Control iOS: added 17 accent palettes with a colorless glass option
  as the default.

## [Unreleased]

### Fixed

- Vamp Control macOS: pointer movement now feels immediate with updated hosts.
  Mac-to-Mac sessions negotiate cursorless video capture and keep the native
  local cursor visible, removing video round-trip delay from pointer feedback.
  Unsent motion is also coalesced to the latest position so a slow data channel
  cannot replay a stale cursor trail. Older peers keep the prior compatible path.
- Vamp Control macOS: Fit Display is a labeled top-bar control again. It used
  to live in an unlabeled icon menu packed into the same toolbar item as
  Screen AI, so hovering Screen AI showed “Fit display” and the sizing button
  looked missing. Fit Display, Fill Window, and Actual Size are also under
  View (⌘0 / ⌘1 / ⌘2).
- Vamp Control macOS: Actual Size now renders the stream 1:1 instead of
  stretching it, and the input mapping clamps to the viewport exactly like
  the renderer. Before, the two disagreed, so the remote pointer drew offset
  from the local cursor (the double-cursor “calibration” problem) when
  Actual Size was selected.
- Vamp Control macOS: the local cursor hides while tracking over stream
  content (and returns when it leaves), so only the remote cursor is visible
  during a session.
- Vamp Control macOS: selecting Actual Size resizes the session window to the
  stream's native size (clamped to the screen), and “Match Window to
  Display” is mode-aware (1:1 in Actual Size, aspect-fit otherwise).

### Added

- Persistent remote sessions: a transport loss now detaches instead of tearing
  down PTYs, so backgrounding the client, network flaps, or app relaunch never
  kill remote shells or agents. Reconnects reattach to the same PTYs (stable
  session/terminal IDs) and replay a bounded, sequence-deduped output tail.
- Durable host session registry (`HostSessionRegistry`) and bounded semantic
  event journal (`HostSessionJournal`) under Application Support — the Mac is
  authoritative across restarts. Raw terminal bytes are never persisted.
- Resume/sync protocol (`sessionSyncRequest` / `sessionSnapshot` /
  `sessionSyncEvent`) that replays missed task-plan and agent events exactly
  once; live semantic messages now carry monotonic `journalSequence` numbers.
- iOS: suspended-workspace lifecycle (tabs stay mounted), background
  checkpointing of the journal baseline, and a quiet "Reconnecting" grace
  state instead of a disconnection flash.

## [2.1.3] - 2026-08-15

### Fixed

- CommandCode (and any interpreter-based agent CLI) now actually answers Chat
  prompts. The Chat semantic runner launched the resolved agent binary with the
  app's minimal GUI PATH, so `command-code`'s `#!/usr/bin/env node` shebang died
  with "env: node: No such file or directory" while self-contained binaries
  (opencode, claude, codex, grok) kept working. The child now inherits the same
  augmented PATH used to resolve the launcher, matching the Terminal PTY.
- Chat responses are no longer clipped to a scrolling middle slice. The browser
  task-chat and the iOS Chat both render the full agent answer inline and follow
  the stream, instead of a fixed-height nested scroll.

### Changed

- Surface the agent's reasoning ("thinking") while it works, in both the browser
  task-chat and the iOS app, so the process is visible rather than only the final
  answer.
- Redesign the browser chat cards — calmer, theme-aware glass surfaces with clean
  headers, readable in both light and dark; clear per-provider error cards; and a
  redesigned, centered pairing card.
- New app icons across the suite: a blood-bag mark for the hosts and a fang mark
  for the clients, full-bleed and premium.

## [2.1.2] - 2026-08-15

### Fixed

- Stabilize the browser-control workspace by coalescing viewport, resize, scroll,
  terminal-output, and tab updates so Safari and Chromium no longer visibly flutter
  during keyboard transitions or streamed terminal output.
- Keep browser pairing in a stable, opaque dialog with a labeled six-digit field,
  keyboard submission, inline errors, and an isolated accessibility focus path.
- Coalesce iOS Terminal workspace invalidations and output activity updates per tab,
  and stop repeated animated scroll corrections from moving the conversation while
  output streams.

### Changed

- Unify Vamp Terminal's iOS Liquid Glass surfaces, control radii, toolbar density,
  and button treatment across the workspace.
- Center the iOS composer controls vertically, add a clear ready state for empty Chat,
  center the empty Terminal state, and show the idle voice action as a mic-only control.
- Group browser terminal keys and session controls, and size the terminal
  viewport to keep the workspace usable across screen sizes.
- Make the Vamp Terminal home screen connection-first, with a more subdued
  light-mode backdrop.

## [2.1.1] - 2026-08-14

### Fixed

- Drop the orphaned Sparkle (and swift-argument-parser) pins from `Package.resolved`
  so the dependency lock matches the real graph (SwiftTerm only). The Vamp Control
  macOS client no longer resolves or embeds Sparkle, removing the launch-time
  library-validation crash caused by the framework's mismatched Team ID.
- Pi and CommandCode now answer Chat prompts through machine-readable adapters
  instead of silently ignoring them in chat mode.
- Collapse the workspace row and tab strip while the mobile keyboard is open so
  the composer no longer floats over the conversation.

### Security

- Enforce the freshness timestamp for every authenticated data-channel command
  in one gate instead of relying on each handler to remember the check.
- Keep signaling envelope IDs for the full replay window plus clock-skew
  allowance, closing a replay gap for future-dated envelope IDs.
- Throttle browser pairing guesses per remote IP instead of globally, and rotate
  the pairing code once an address exhausts its guess budget.
- Draw browser pairing codes and tokens from `SecRandomCopyBytes` explicitly.
- Move the browser WebSocket bearer token out of the URL query into the
  `Sec-WebSocket-Protocol` handshake header (macOS host and Linux host), so it
  no longer leaks into browser history, referrers, or logs.
- Add a client→PTY input byte budget mirroring the existing output budget.

### Changed

- Refresh the Vamp Terminal, Vamp Host, and website icon with the supplied glass terminal mark.
- Bump the Vamp Terminal sideload build to build 3 after the release rebase and host hardening audit.
- CI: run the core suite on an arm64 runner and build the unsigned iOS device
  slice on every run; run all test suites before packaging a release; verify
  release checksums round-trip and fail loudly when the SBOM generator is missing.

## [2.1.0] - 2026-08-14

### Added

- Vamp Suite 2.1: unified clients and terminal hosts, terminal workspace and
  semantic chat overhaul, unified Vamp interface design.
- Agent CLI resolution outside Homebrew paths.

### Security

- Require a verified `--fingerprint` for every `vamp approve-*` action and make
  `vamphost://` approval links inert (fingerprint-bound approval only).
- Wire the Linux host and browser VT test suites into CI.

### Fixed

- Broken download links on thevamp.app.
- Safari terminal ready routing; terminal chat stability.
- iOS terminal error banner no longer overlaps content; clearer missing-tool text.

## [1.0.10] - 2026-08-04

### Fixed

- Normalize SDR screen capture to sRGB, BT.709, and full-range pixels before
  encoding, and carry matching color metadata through VideoToolbox so dark UI
  content is not rendered with a faded low-contrast veil.
- Keep the iOS and Mac client decoders on the same sRGB transfer-function
  contract for SDR frames.

## [1.0.9] - 2026-08-03

### Changed

- Rename the public product to MacPair with shorter installed app names and
  clearer open-source Mac remote desktop positioning.
- Keep the `screenharbor` CLI, bundle IDs, URL scheme, Bonjour service, and
  persisted storage identifiers compatible with existing installations.

## [1.0.8] - 2026-08-03

### Fixed

- Keep Mac and iOS client EDR presentation synchronized with the decoded frame's
  actual dynamic range, so an SDR fallback is not displayed with HDR tone mapping.
- Tag decoded SDR frames as BT.709 for consistent color interpretation in the
  sample-buffer display layer.

## [1.0.7] - 2026-08-02

### Fixed

- Stop the Host Screen Recording prompt storm: status polls no longer call
  `SCShareableContent` while unauthorized (that API itself presents the system
  sheet), automatic refresh never opens CG/AX dialogs, and each permission
  kind may show at most one OS prompt per process from an explicit Fix/Open
  Settings action.

## [1.0.6] - 2026-08-02

### Changed

- Remove the Mac client reconnect dimming scrim so the last remote frame
  stays full brightness while reconnecting; the reconnect card still appears.

## [1.0.5] - 2026-07-31

### Fixed

- Stop treating a transient ScreenCaptureKit probe error as Screen Recording
  denial, so the Host reads an approval that CoreGraphics already sees
  (common right after granting permission from the 1.0.4 DMG).
- Re-check Host permissions when returning to the app and while setup
  blockers remain, and re-prompt Accessibility as well as Screen Recording
  after an ad-hoc binary identity change.

## [1.0.4] - 2026-07-31

### Fixed

- Detect when an ad-hoc Host rebuild invalidates Screen Recording /
  Accessibility grants, re-prompt for the new binary, and tell the operator
  how to remove the stale System Settings entry.

### Changed

- Give ScreenHarbor Host and ScreenHarbor distinct macOS app icons (bloodbag
  host, fang client), with matching splash artwork.

## [1.0.3] - 2026-07-29

### Added

- Add the open-source Vamp Terminal iPhone/iPad client for iOS 18 and later.
- Add reproducible unsigned IPA packaging with SHA-256, source manifest, and
  CycloneDX SBOM output for user-controlled sideload re-signing.
- Add iOS sideloading and agent-discovery documentation.

### Changed

- Use the Vamp bundle identity and the existing `_screenharbor._tcp` discovery contract
  contract throughout the iOS client.
- Remove the obsolete App Store paywall and daily streaming cap from the
  direct/open-source iOS build.

### Fixed

- Make website release staging idempotent when the Vamp site is already marked live.
- Keep website checksum, manifest, SBOM, and software-version links synchronized
  with each staged release.
- Make future-device Ultra-quality policy tests independent of the CI runner's
  hardware HEVC decoder.
- Align CodeQL action pins and use its no-build C/C++ mode to remove workflow
  compatibility warnings.
- Install the Metal build component in CodeQL and include the iOS client in the
  audited Swift target set.
- Keep direct-distribution settings local so iOS launch does not require an
  unavailable iCloud KVS entitlement.

## [1.0.2] - 2026-07-29

### Fixed

- Pin OpenSSF Scorecard to the dereferenced v2.4.3 commit so its provenance
  verifier accepts the workflow action.
- Remove the Sparkle runtime, update controls, feed metadata, packaging hooks, and
  release metadata. This prevents launch-time failures when macOS rejects the
  bundled Sparkle framework signature in an ad-hoc distributed app.

## [1.0.1] - 2026-07-29

### Fixed

- Commit the complete application dependency lock, including Sparkle 2.9.4, so
  release packaging does not dirty the source tree.
- Recheck source-tree cleanliness after packaging before allowing publication.
- Update SwiftTerm to 1.15.0 and refresh pinned GitHub security actions.

## [1.0.0] - 2026-07-29

### Added

- Public macOS host and client applications for direct website distribution.
- Local-first discovery, approved peer pairing, screen and input control, clipboard
  sync, file transfer, audio, and opt-in terminal access.
- Agent-safe CLI, machine-readable manifest, and LLM discovery documentation.
- Reproducible dependency locks, release manifests, checksums, and CycloneDX SBOMs.
- Community governance, security, contribution, support, and trademark policies.

[Unreleased]: https://github.com/Mesutcydev/vamp-suite/compare/vamp-suite-2.1.2-build-36...HEAD
[2.1.2]: https://github.com/Mesutcydev/vamp-suite/releases/tag/vamp-suite-2.1.2-build-36
[2.1.1]: https://github.com/Mesutcydev/vamp-suite/releases/tag/vamp-suite-2.1.1-build-34
[2.1.0]: https://github.com/Mesutcydev/vamp-suite/releases/tag/vamp-suite-2.1.0-build-33
[1.0.10]: https://github.com/Mesutcydev/vamp-suite/compare/v1.0.9...v1.0.10
[1.0.9]: https://github.com/Mesutcydev/vamp-suite/releases/tag/v1.0.9
[1.0.8]: https://github.com/Mesutcydev/vamp-suite/releases/tag/v1.0.8
[1.0.7]: https://github.com/Mesutcydev/vamp-suite/compare/v1.0.6...v1.0.7
[1.0.6]: https://github.com/Mesutcydev/vamp-suite/compare/v1.0.5...v1.0.6
[1.0.5]: https://github.com/Mesutcydev/screenharbor/compare/v1.0.4...v1.0.5
[1.0.4]: https://github.com/Mesutcydev/screenharbor/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/Mesutcydev/screenharbor/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/Mesutcydev/screenharbor/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/Mesutcydev/screenharbor/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/Mesutcydev/screenharbor/releases/tag/v1.0.0
