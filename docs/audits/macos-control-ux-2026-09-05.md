# Vamp Control macOS UI/UX audit

Date: 2026-09-05. Scope: the macOS client, Vamp Sync and Vamp Assistant connections.

The highest-value improvement is predictable input: people must know which Mac receives their keys, and a visible stream must not imply that input is ready. Simplify the session toolbar after that; a visual redesign alone will not address the reported failure.

## Evidence and limits

Inspected the installed client's host list visually and through accessibility, and reviewed the session, input, settings, host discovery and menu implementations. The installed app's UI inspection timed out after an existing Assistant reconnect was attempted. No remote editing or pairing approval was performed. Streaming findings below are source-based, not measurements of a successful live session. Competitor comparisons use vendor documentation, not hands-on benchmarks. No latency or picture-quality ranking is claimed.

## Prioritized findings

| Priority | Finding and evidence | Recommended implementation | Acceptance |
| --- | --- | --- | --- |
| P1 | Physical arrows fail, as reported. `MacVideoStreamView.swift` relies on ordinary `keyDown` delivery, while `performKeyEquivalent` handles only Command combinations. Arrow mappings already exist for both transports. SwiftUI navigation interception is a plausible failure path; the live root cause remains unconfirmed. | Handle arrows before local focus navigation, strictly scoped to the key window's focused stream. Preserve repeat/modifiers and release held arrows when focus or control is lost. | All four arrows move a remote editor caret; Shift selects; Option moves by word; holding repeats. Local fields, dialogs and other windows receive their own arrows. |
| P1 | Full control / view-only is icon-only, with explanation behind hover. There is no visible indication that the stream currently owns keyboard focus. See `sessionToolbarTogglesCluster` and Assistant `accessModeButton`. | Keep a short visible “Control” / “View only” label. When enabled but unfocused, show “Click the stream to control”. Show keyboard ownership separately from connection status. | A new user can explain why typing does nothing without discovering a tooltip. Focus indication clears when a local sheet opens. |
| P1 | Input readiness is inconsistent. The Sync surface disables for error and lock, but not explicitly for the app browser or every reconnect phase. Several toolbar sends check only session ID and view-only. | Derive one readiness state from live attachment, selected stream and control permission. Apply it to the surface and all send actions, including Command-Tab. | No remote command is queued while choosing an app, reconnecting, or entering a local unlock password. Never weaken trust/permission checks. |
| P2 | Two View menus are visible in the installed menu bar. `MacClientApp.swift` adds `CommandMenu("View")` beside the system View menu. | Insert sizing commands into the native View menu. Implemented in this change. | One View menu contains window commands and Fit / Fill / Actual Size. |
| P2 | The session toolbar combines host/quality, sizing, clipboard, capture, file transfer, terminal, remote Command-Tab, AI, audio, control mode, stats and disconnect. Some appear as indivisible HStack clusters. | Primary: host/status, Apps or Display, sizing, Control, Disconnect. Put clipboard/capture/files/terminal/AI under a labeled Tools menu; keep an optional customizable quick action. | At the 760-point minimum width and with stats enabled, primary controls stay available and secondary actions remain reachable by keyboard. |
| P2 | Assistant reserves toolbar space for unavailable tools and audio. Its toolbar structure differs from Sync. See `MacAssistantRemoteView.swift`. | Share a capability-driven toolbar model. Put unavailable features and an explanation in connection details instead of permanent disabled buttons. | Both host types use the same control order and labels; only supported actions are offered. |
| P2 | A saved Assistant with a Reconnect action sits under “Pair with a code”. Verified in the installed host list. | Use “Saved connections” for paired entries and make “Pair Assistant” the add action. | Existing users reconnect without being told to pair again. |
| P2 | The host-list illustration competes with small metadata and section labels. Existing cards help, and reduced-transparency support already exists in `MacBrand.swift`. | Lower background prominence behind content, strengthen section labels and secondary text, keep the artwork strongest in empty areas. | Check light/dark, increased contrast and reduced transparency on the actual window; do not claim a contrast failure without measuring colors. |
| P3 | Keyboard behavior is distributed across menus, toolbar tooltips and `RemoteKeyEquivalentPolicy`. Local Command-0/1/2 and Command-R reservations may surprise remote-app users. | Add a Keyboard menu/help panel listing “Kept on this Mac” and “Sent to remote Mac”, plus explicit Send Key actions for OS-reserved shortcuts. Consider configurable mappings later. | Shortcut documentation matches routing tests; Disconnect remains easy to reach. Do not introduce global key capture. |

## Competitor inspiration

| Product | Documented pattern | Adaptation for Vamp |
| --- | --- | --- |
| Apple Screen Sharing | Native View controls include scaling, adaptive/full quality and observing/controlling; high-performance sessions expose additional display options. [Apple guide](https://support.apple.com/en-ie/guide/mac-help/mh14066/mac) | Put sizing and control mode in predictable native locations, and expose quality choices where the user sees the stream. Keep advanced options conditional on host capability. |
| Jump Desktop for Mac | Dynamic resolution matching and live display settings reduce mismatch between local and remote dimensions. This is documented in historical Mac release notes, not a claim about a newly released feature. [Mac release notes](https://jumpdesktop.com/redir/new_mac_inapp/index-80221.html) | Build on Vamp Sync's existing viewport reporting. Offer a clear fit-to-window choice and remember display mode per host instead of one global preference. Avoid promising virtual displays on unsupported hosts. |
| Jump Desktop browser client | Provides quick access to shortcut keys, including additional arrows/function keys on mobile. This is a browser example, not a claim about its macOS toolbar. [Browser release notes](https://changelog.jumpdesktop.com/fluid-2.0-in-browser-experience-uMERG) | Use a small Send Key menu for difficult shortcuts; physical keyboard reliability remains the default path. |
| AnyDesk | Session toolbar separates display, keyboard, permissions and actions; indicates fresh image data and supports selecting displays. [Session settings](https://support.anydesk.com/docs/session-settings) | Group by user intent. Connection details should distinguish transport connected, receiving frames and control available. Use display thumbnails already present in Vamp rather than adding another display picker. |

These are interaction patterns to adapt, not designs to copy. Vamp's useful distinction is app-window streaming combined with terminal access over its existing private, authenticated connection.

## Recommended delivery order

1. Validate arrow routing in both active host paths and ship the native View-menu correction.
2. Add keyboard-focus feedback and a shared input-readiness gate. This addresses “looks connected but does nothing”.
3. Consolidate the toolbar and explain unavailable capabilities. Verify at minimum window width.
4. Improve saved-connection wording/background legibility, then add per-host sizing and keyboard preferences.

## Changes and verification

This patch adds a local arrow event monitor shared by the Sync and Assistant streaming surface, preserves down/repeat/up and modifiers, and releases held arrows when focus is lost, input is disabled, the window resigns key or the view detaches. Right/middle clicks now also focus the streaming surface. Sizing actions join the native View menu.

Regression tests cover all four arrows, repeated key-down, modifiers, local-focus pass-through, unrelated shortcuts, unmatched releases and releasing held keys exactly once. See `MacClient/Tests/RemoteInputPolicyTests.swift`.

Before calling the user-reported bug fully resolved, run a trusted live session against both Sync and Assistant with a disposable remote text buffer. Verify arrows before/after toolbar use, a local sheet, view-only, window switching and reconnect. Check remote caret/selection movement, not just successful enqueue. Test Control-arrow system shortcuts through explicit Send Key actions if macOS reserves them; the local monitor cannot intercept OS-consumed shortcuts.

Validation result: `xcodebuild -project MacClient.xcodeproj -scheme MacClient -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/vamp-control-audit-build CODE_SIGNING_ALLOWED=NO test` succeeded: 29 tests, zero failures, including the three new arrow-monitor tests. The application target also compiled. `git diff --check` passed. Changes are confined to the macOS client; no shared protocol/host sources changed. The installed application was not replaced. A live remote caret test remains outstanding because UI inspection timed out.

## Implementation follow-through

The follow-up implements the four delivery stages in order:

1. **Keyboard:** the shared native stream surface forwards physical arrows before SwiftUI focus navigation; Command equivalents now require stream focus, so local fields retain their own shortcuts. Arrow releases survive focus loss, and queued interactions are discarded when input pauses. Explicit Send Key commands include arrows, Control-arrows, Command-Tab, Command-Space and Escape.
2. **Readiness and focus:** both connections use the same readiness policy for reconnect, lock, app selection, video availability and view-only. The view-only/control choice has an explicit text label. An unfocused stream explains that it needs a click; connection details distinguish connection, video, control availability and keyboard ownership. File sending rechecks readiness and the target session after the file picker returns.
3. **Toolbar:** shared Control and Tools components, capability-dependent actions, primary app/display and sizing controls, optional per-connection quick action, live stats outside the toolbar, and connection details explaining unavailable functionality. Sync offers live stream quality changes through the existing quality-adjust API. The native title remains available to accessibility and Window menus but no longer duplicates the host name in the toolbar.
4. **Connection preferences and legibility:** saved Assistant wording, stronger section headings, a quieter backdrop with increased-contrast/reduced-transparency handling, per-host display sizing and local/remote Command-0/1/2 routing. The View menu edits the active connection's binding. Defaults migrate from the previous global display mode. Assistant Actual Size now uses backing pixel scale for Retina 1:1 presentation and matching pointer coordinates. Empty-state copy directs users to active hosts instead of promoting discontinued Vamp Host.

No protocol, host, trust or persistent-session implementation was changed. No installed app was replaced.

### Verification evidence

- The updated Debug app's host list was inspected visually and through accessibility: Saved connections, stronger headings and one View menu were visible.
- A separate Debug-only local fixture exercised the production `RemoteStreamNSView` and shared toolbar controls without contacting a host. Four physical arrow presses produced exactly four down events and returned the position to its origin. Arrows in a local text field and keyboard-help sheet did not increase the remote event count. View-only blocked a physical arrow. The keyboard-help sheet was checked visually.
- That visual check found macOS automatically hiding Control/Tools text; explicit label styles and removal of the redundant native title were applied afterward.
- An attempted Sync connection requested new host approval and was canceled. No trust request was approved. Remote end-to-end arrow behavior therefore remains unverified.
- The Mac locked before the final toolbar check. Minimum-width layout with the latest explicit labels, dark/light and accessibility appearance checks, and the real remote caret/reconnect checks remain pending. The earlier fixture was 860 points wide, not the 760-point minimum.

### Repeating the local UI check

`MacSessionUXPreview.swift` is compiled only in Debug. To run it, copy a Debug app to a temporary location, give the copy a distinct bundle identifier, add Boolean `VampUXAudit = true` to its Info.plist, and ad-hoc sign the copy. The fixture uses the real native event surface with a local input recorder and never opens a remote connection. It does not validate host injection or transport behavior. The temporary copy used here is `/tmp/Vamp Control UX Check.app`.

Final code validation: 39 macOS tests passed with zero failures. The Release application build also succeeded for arm64 and x86_64. `git diff --check` passed. Build logs remain in `/tmp/vamp-control-ux-final-tests.log` and `/tmp/vamp-control-ux-release.log`; they are not repository artifacts. Final visual and trusted remote-session acceptance remains pending as described above.

### Release follow-up: build 53

After the Mac was unlocked, the final native fixture was checked at 760 points. This exposed two overflow cases: a pinned quick action and the longer View only label could displace Disconnect. The release fixes those cases with compact host/sizing labels and a quick action that appears only in wide windows. Both Control and View only now leave Disconnect visible at 760 points; selecting a quick action does not displace it. At 1050 points the selected quick action appears beside the other controls. Tools continues to offer the action at every width. The latest native regression run still passes all 39 tests.

Trusted remote-host caret verification remains unperformed because the connection requested new trust approval. Local physical-key delivery and focus isolation were verified as described above; no host permission or trust approval was bypassed.


## Follow-up: restore desktop control and reduce toolbar chrome

User feedback on build 53 identified a duplicated host title, oversized toolbar
capsules, and app streaming replacing the expected full-desktop experience.

Control build 54 uses a compact native toolbar with one host label, a Desktop/App
source menu, display sizing, access mode, Tools, and a neutral Disconnect action.
The macOS 26 shared toolbar background is hidden to avoid stacked capsule effects.
A native preview verified the 760-point minimum width and four arrow-key events.

Sync build 65 accepts desktop control from clients advertising the new explicit
`supportsDesktopControl` capability together with `supportsMacClient`. Control 54
opens the desktop by default and can switch to apps and back through the source
menu. Existing Control builds and Vamp Stream keep their app-first handshake.
Both Control 54 and Sync 65 are needed for desktop control over Sync. Assistant's
existing desktop transport remains available. No discontinued host is restored.

Window mapping no longer produces a spurious missing-display warning. Reconnect
clears stale window coordinates before the new desktop attachment. Invalid display
choices preserve the existing window; capture failure attempts to restore it.

Validation: 595 Swift package tests, 39 native Mac client tests, and 32 Python
script tests pass. Active Sync, Terminal, and Stream Xcode schemes build. Live
remote desktop/app switching still requires validation on the updated remote host;
no new pairing or macOS privacy permission was approved during these checks.
