# iOS instrument presentation migration — 2026-09-08

## Scope

The user's subsequent refinement prompt supersedes further redesign. The follow-up changes retain the current composition and information architecture.

Production `BeetCodeRemoteIOS` target only. This pass builds on the existing uncommitted cardless Settings, model browser, sharing, pairing, transcript, and adaptive navigation work. No Mac or website presentation changes are part of this iOS pass.

The request is implemented through the existing production view entry points, not an alternate demo application. Repeated materials remain centralized in `RemoteInstrument`, `remoteFaceplate`, `remoteRecess`, `VampHairline`, `VampMicroLabel`, and the shared button/segment styles; the deck adds shared `VampHardwareSeam` and `VampDeckIcon` components.

## Implemented

- Rebuilt the composer deck: recessed editor, channel seams, widest model bay, four-dot Tools key, dark Chat/Code readout, dedicated send/stop/queue bay, and status strip.
- Normal empty portrait geometry is approximately 182pt before external docking insets. Accessibility uses a separate stacked model/actions/send composition; compact-height layouts omit the status strip when possible.
- Centered 800pt maximum composer width; wide layouts expose Share/Tools labels and rebalance the bays. Mode yields to keyboard dismissal while editing. Removed the whole-deck focus animation after capture revealed an out-of-bay transient.
- Session inventory rows use a 72pt minimum, title/technical metadata/time hierarchy, meaningful running indicator, recessed selection, and orange index. Accessibility stacks metadata and removes header clipping.
- Removed every iOS bot portrait reference and the thumbnail component. Indexed specialist identities are used in the library, chooser, and workstation. No shared Mac image assets were deleted.
- Rebuilt bot chooser as a continuous inventory, retained separate Chat/Run presentation, and constructed a compact orchestration faceplate with a recessed outcome editor.
- Neutral silver/graphite material palette; focus uses a precision orange index instead of an editor-wide orange outline. Connection retry uses a semantic orange indicator rather than the saved custom accent.
- New-session workspace selection reflows at accessibility sizes; iPad user message width is limited to 58% of the reading column.

## Preserved behavior

This presentation pass does not alter stores, API protocols, credentials, permissions, pairing, streaming, session persistence, or authorization. Composer callbacks still use the existing send/queue/steer/stop handlers. Model selection remains unavailable during a turn. The mode insert reports the actual session mode; it does not pretend to be an unsupported mode-switch action.

## Verification evidence

- Baseline: 26 iOS regression tests passed before the presentation edits.
- Added `RemoteInstrumentRenderingTests` in the iOS test target. It hosts real production views with in-memory fixture stores and exports named light/dark XCTest image attachments.
- Initial post-migration iPhone and iPad runs: 27 tests passed on each, zero failures.
- Final verification results and exported images are in the Desktop `Vamp iOS Instrument Audit` folder.
- A separate Argent system capture verifies the actual iPhone keyboard, editor, dismissal key, send bay, and docking. UIWindow fixture renders alone do not include the system keyboard.
- `git diff --check -- iOSApp iOSTests` passed.

## Screenshot matrix mapping

Phone captures 01–17 correspond to the requested screen names, plus 20 for short-height landscape. iPad includes the same production screens plus 18 Sessions split, 21 Bots split, and 24 reduced width. Requested iPad 19/22/23 correspond to iPad 01 Chat, 10 Models, and 16 Settings. Split captures include the genuine unselected workspace state; specialist detail is also captured separately in both Chat and Run modes.

These are explicitly labeled fixtures, not evidence of successful live pairing, remote execution, or streaming. Resized-window renders test layout constraints, not physical-device rotation behavior. The host app may restore its existing saved connection on launch; the fixture stores themselves contain no saved computers or credentials.

## Release boundary

This is a presentation/build verification pass, not a claim of release certification. Physical-device interaction, VoiceOver traversal, interactive keyboard dismissal while streaming, selected iPad split navigation, and live approval round trips still require end-to-end verification. No IPA was installed, published, or uploaded by this iOS pass, and no permissions were reset.

## Follow-up refinement findings

| Before | After | Why |
| --- | --- | --- |
| Bots and conversation warnings had separate spacing, colors, and icon sizing | Shared `RemoteNoticeLabel`, 12pt inset, fixed warning glyph, semantic warning marker | Consistent warning hierarchy without changing the Retry handler |
| Enlarged warning text competed with a trailing Retry label | Warning action reflows below the content and remains visible | Preserve the affordance at Dynamic Type sizes |
| Settings row icons expanded to different widths with their labels | 28pt icon column and wrapping text | Stable alignment without shrinking accessible text |
| Long authorization summaries could expand the whole approval panel | `RemoteApprovalSummary` measures short text and caps long text at a scrollable 140pt | Keep the complete request readable and decisions reachable |
| Approval answer field used a one-off background/radius | Shared recessed input material | Consistent light/dark input construction |

Portrait retains the established control deck and uses stacked accessibility layouts. Landscape has a compact editor and omits redundant status chrome; wide decks expose labeled utilities and distribute width across functional bays. Dark mode uses separate neutral canvas/chassis/recess/insert levels, not a blanket inversion. Existing accent choices still color action affordances; warning and connection state markers retain their semantic colors.

### Test-run caveat

The combined two-destination run at 12:22 did not finish: `testOldMacMutationFailuresDoNotAlertOnNewMac` was reported failed at 0.000 seconds, the test process restarted, and Xcode entered simulator diagnostics. That runner was terminated rather than counted as a pass. The standalone iPad retry at 12:28 passed; final refinement verification is recorded separately. This event should not be hidden by subsequent successful runs.

### Refinement verification

- iPhone at 12:32: 27 tests, zero failures, including the previously failed concurrency test.
- iPad at 12:34: 27 tests, zero failures.
- Unsigned generic iOS Release build succeeded after the shared warning/approval refinements.
- Desktop `Final-iPhone` and `Final-iPad` contain the named production-view fixture renders. Captures 25/26 additionally exercise long warnings and bounded approval text at accessibility size.
- The pixel-diff service could not read the Desktop images (`EPERM`); no visual-diff pass is claimed. Direct image inspection was available and used. No privacy permissions were changed to work around the tool failure.
- Snapshot runs log UIKit appearance-transition and repeated scroll-geometry warnings while swapping/resizing hosting windows. These are retained as harness/runtime edge cases, not silently declared resolved.

### Final compact-height verification

- Reduced compact-height composer keys, status chrome, and notice padding while retaining 44pt control targets. The iPhone suite at 12:36 passed all 27 tests.
- Replaced the connection-lost screen's fixed-height content with a scrollable, minimum-height layout. Reconnect and Back remain available when enlarged text exceeds a landscape viewport.
- The added short-height connection test passed at 12:38 in light and dark accessibility-size fixtures. This targeted test ran after the full suites; a combined 28-test suite was not rerun.
- The final unsigned generic iOS Release build succeeded after these changes.
- The clean Desktop `Vamp iOS Instrument Audit/Review` folder contains 42 iPhone and 46 iPad fixture images, plus the separately labeled actual simulator keyboard capture. Image 27 covers connection-lost landscape at accessibility size. The system keyboard capture predates the final compact notice-padding refinement and verifies keyboard docking, not every final pixel.
