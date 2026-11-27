# Agent prompt — Vamp Assistant host: match the Vamp Stream window-sizing and resolution fixes

Copy everything below the line into the agent working on the Vamp Assistant host.

---

## Task

Bring the Vamp Assistant **macOS host** (repo: `/Users/m/Downloads/beetcode/BeetCode`, the
`BeetCode` Xcode project — this is the product published as *Vamp Assistant*) to parity with the
Vamp Stream / Vamp Sync window-sizing fixes. The Stream client is in a different repo
(`vamp-suite`); you are only changing the host. The installed host today is **0.10.35 build 93**.

Three of the required changes are real defects that reproduce the user-reported symptom:
**a streamed Mac window does not take the phone's portrait shape, and the picture is soft because
the host captured a smaller window than the phone renders.**

Capability facts about the current host (verified, do not regress): it already honors `cursor=0`
(`RemoteSessionHost.swift` → `showsCursor: request.query["cursor"] != "0"`), already advertises
`supportsCursorlessCapture: true`, already publishes 192 px icon tiles
(`iconTilePixels = 192`, aligned with the Sync host), and its `targetWindowFrame` already matches
the requested aspect and fits it into the display.

### 1. Required — the AX resize is applied in the wrong order (root cause)

`App/RemoteControlApplicationRegistry.swift`, `resizeFocusedWindow(pid:toAspect:preferredBounds:)`
(currently lines ~343–401) sets the window's **size first**, then its **position**:

```swift
_ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)   // size first
...
var requestedPosition = targetFrame.origin
if let positionValue = AXValueCreate(.cgPoint, &requestedPosition) {
    _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) // then move
}
```

AppKit constrains a window's frame to the screen when its size is applied, so a window sitting low
on the display has its height silently clamped to what fits below its *old* origin. The window then
keeps a different shape than the requested aspect, the phone renders it letterboxed, and the
capture is smaller than the phone's screen — so the phone upscales it. The Stream client surfaces
exactly this as *"The Mac kept a different window shape. Zoom or pan for a closer view."*

Fix (the Sync host does this in `HostSessionCoordinator.resizeWindow`; mirror it):

1. Compute the anchor from the **requested** size — never from a freshly-read AX frame, because an
   AX size set is applied asynchronously and an immediate read returns the old frame.
   Clamp the anchor inside the usable area:
   `x = max(display.minX + 24, min(current.minX, max(display.maxX - requested.width - 24, display.minX + 24)))`,
   `y = max(display.minY + 52, min(current.minY, max(display.maxY - requested.height - 24, display.minY + 52)))`.
2. **Set the position first**, then the size.
3. Re-assert the size once if the frame still differs by > 2 pt (idempotent; covers apps whose AX
   set lands before the move settles).
4. Keep the existing `Task.sleep(for: .milliseconds(350))` + snapshot re-read in
   `resize(windowID:clientViewportAspect:)` — that part is correct and is what makes the returned
   `width`/`height` authoritative.
5. Log the outcome (observed vs requested geometry, and whether a retry ran) at a level that
   survives in the host's normal log, so a live failure is diagnosable without a special build.
   Never log window titles or content.

### 2. Required — a window can exceed the decoder envelope on total pixels

`Core/Tools/RemoteMacScreenCapture.swift` (~lines 206–215) already caps the **longest axis** and
rounds both axes to even — keep that. But `RemoteStreamProfile.maxWidth` (3840 for
`RemoteStreamResolution.native`) is the only ceiling, so a near-square window such as 3800×3800
(14.4 MP) passes and is far past what the client's decoder and the Mac's encoder are budgeted for
(a 4K UHD frame is 3840×2160 = 8.29 MP).

Fix: apply both ceilings, shrink-only, aspect preserved, both axes even:

```swift
let longest = max(pixelWidth, pixelHeight)
let pixels  = pixelWidth * pixelHeight
let edgeScale  = Double(maxLongEdge) / Double(max(longest, 1))     // maxLongEdge = 3840
let pixelScale = (Double(maxPixels) / Double(max(pixels, 1))).squareRoot()
let scale = min(1, edgeScale, pixelScale)                          // maxPixels = 3840 * 2160
let width  = max(2, Int((Double(pixelWidth)  * scale).rounded(.down) / 2) * 2)
let height = max(2, Int((Double(pixelHeight) * scale).rounded(.down) / 2) * 2)
```

Keep `capture width/height` and `encoder.configure(width:height:)` fed from the **same** `width`
and `height` values; VideoToolbox rescales mismatched input, which wastes bandwidth and blurs the
image.

### 3. Required — `native` runs at 30 fps, the pair can do 60

`Core/Tools/RemoteStreamProfile.swift`: `native` is 30 fps / 32 Mbps, while Vamp's quality/ultra
tiers are 60 fps and its ultra bitrate cap is 48 Mbps. A 4K-class native window stream at 30 fps is
not the maximum the hardware supports (A19 Pro decode and the M4 media engine are both 4K60).

Fix: `native` → 60 fps, and raise its bitrate to the ~48 Mbps ceiling Vamp uses for ultra or scale
its bits-per-pixel target for 60 fps, whichever keeps the host's own local budget. If you decide
30 fps must stay for a host-side reason, say so in your report with the measurement that justifies
it rather than leaving it implicit.

### 4. Recommended — AX window matching can resize the wrong window

`axWindow(pid:matching:)` (~lines 270–305) returns the app's **focused window** whenever a non-nil
`bounds` matched nothing, and it matches on origin only. `resize(windowID:)` passes the named
window's bounds, so a mismatch — or two windows of the same app at the same origin — silently
reshapes a different window than the one being streamed. The Sync host deliberately refuses in that
case (`matchingWindowIndex` requires exactly one candidate matching origin **and** size) and never
falls back to focus.

Fix: match on origin **and** size within 2 pt, require a unique match, and return
`RegistryError.windowUnavailable` (or a "could not resize this window" result) instead of reshaping
the focused window. Keep the focused-window fallback only for the launch path, where no bounds are
known yet.

### 5. Optional, two-sided — exact dimensions, sizing mode, original restore

The resize API is aspect-only: no `viewportWidth`/`viewportHeight`, no `sizingMode`, no
`appliedSizingMode`, no original-bounds cache. So the Stream client can only offer *Original
proportions* and must tell the user that exact Original Size restoration needs host support. The
Sync host's equivalent (`StreamTargetSwitchRequestMessage`) carries
`viewportWidth`/`viewportHeight`/`sizingMode`, acknowledges with `appliedSizingMode`, and restores
cached original bounds.

Do **not** start this without coordination: the Stream client's Assistant path
(`BeetCodeRemoteClient.resizeApplication`) currently sends only `windowID` and
`clientViewportAspect`, so the client needs a matching release. If you take it on, treat it as a
separate change with an additive, optional wire surface (older clients must be unaffected) and
report the client-side fields Stream will need. Leave it out otherwise.

## Do not change

- `cursor=0` handling and the `supportsCursorlessCapture` advertisement.
- `iconTilePixels = 192`; keep the Assistant's tile size equal to the Sync host's.
- The aspect-exact `targetWindowFrame` policy (viewport aspect, fit into the usable display, the
  96×72 minimum clamp). Do not reintroduce a width floor — a floor above `height * aspect` is what
  letterboxes a portrait phone.
- The 350 ms settle + snapshot re-read, the `desktopIndependentWindow` filter, and the capture /
  encode dimension lockstep.
- Anything about pairing, trust, Screen Recording or Accessibility consent, or the bundle
  identifier. Never reset TCC permissions.

## Working-tree caution

The checkout has uncommitted changes from another session's work. Do not revert or lose them: work
on your own branch or worktree rather than resetting the tree, and do not regenerate the project
while a build is running.

## Verification

Follow the repo's `AGENTS.md`:

```sh
xcodegen generate                          # after adding/removing files only
xcodebuild -project BeetCode.xcodeproj -scheme BeetCode \
  -destination 'platform=macOS' -derivedDataPath .derived test
```

Add unit tests for the pure geometry you touch, and state explicitly what they do and do not prove:

- `targetWindowFrame` / the new ceiling: long edge ≤ 3840 and pixels ≤ 8.29 MP for a near-square
  window, aspect preserved, both axes even, never upscaled, and real hardware sizes unchanged
  (e.g. a 2560×1440 Mac producing a 1334×2728 portrait window must pass through untouched).
- `RemoteStreamResolution.native` reports 60 fps with the intended bitrate.
- The AX ordering itself cannot be unit-tested without a live window; say so, and verify it live
  instead: open an app, stream it to a portrait phone (or call
  `POST /api/control/apps/resize` with a portrait `clientViewportAspect`), and confirm the returned
  `width`/`height` match the requested aspect. A window whose origin is low on the display is the
  case that used to fail — that is the shape the fix must hold for.
- Report the observed before/after geometry (points and the resulting capture pixels) and the host
  build you verified on. Do not claim device-visible results you did not observe.
