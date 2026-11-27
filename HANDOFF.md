# Handoff: Vamp Sync and Vamp Control audit (2026-11-20)

**Branch:** `codex/stream-startup-0.1.18` · **Uncommitted** · 143 files changed · nothing committed or pushed.
Delete this file once its open items are closed or moved to the tracker.

## Read first

- `AGENTS.md`: the safety rules. Never approve a pairing, never weaken pairing, replay, session-ID or terminal-ID checks, never commit credentials.
- `CHANGELOG.md`, section `[Unreleased]`: every fix made in this audit, in user-facing words.
- The working tree mixes this audit with the user's earlier uncommitted work. Do not run `git add -A`, `git checkout --`, or reformat files you did not write. Commit by area.

## Constraints

- Disk: about 3 GB free. Reuse one derived-data path for Xcode builds (the session used `.../scratchpad/dd`). Do not run `disk-clean`, `erase`, `delete` or `clone`.
- Do not package, notarize, release or upload anything without the user's go-ahead.
- Do not start a second host on the user's Mac, and do not approve pairing or trust prompts.
- The Sync 4.0.0 (build 84) and Control 2.0.0 (build 68) notarized builds predate every change here. They are not the current code.

## Done (in the working tree, unverified live)

**Streaming quality and resolution**
- Display streams size from backing pixels (`CoreGraphicsDisplayLayoutProvider.backingScale`), used by both encoder and capture. Previously Retina desktops streamed at half resolution per axis.
- 4K-UHD pixel budget (`StreamScaling.decoderCeiling`) now applies to display streams. Long-edge limit stays window-only.
- Encoder re-applies the last adaptive bitrate on session rebuild (`HostSessionCoordinator.startAdaptiveStreamingControl`).
- Display switch keeps the negotiated preset (no more forced Balanced).
- Client: idle is not stalled, so no keyframe storm (`VideoFrameDecoderView.requestKeyframeIfStalled`). Loss EMA follows encoder sequence restarts (`WebRTCSessionManager`). Ping loss is a 30-sample window (`PingLossWindow`). `.excellent` counts toward recovery. Upgrade latch re-arms on downgrade.

**Sync host**
- Client reset stops secondary displays and the display observer, and cancels adaptive control (`resetForNextClient`).
- App-window sessions never fall back to whole-display capture (`handleObservedDisplayLayoutChange`).
- A failed window start stops its pipeline. A failed display-switch fallback stops capture before restarting.
- Stop pressed during Start is honoured (`HostAppEnvironment.startRuntimeIfNeeded`).
- Offer configures the session only after the trust gate. Identity match uses the key when both sides present one (`HostClientAttachmentIdentity`).
- Clipboard read and write are refused when the Mac is locked, and writes are refused in view-only mode (`HostInputCommandRouter`).
- Port-conflict copy no longer names discontinued products. Copy Pairing Address is disabled without an address.

**Connection**
- Peer close on the data socket is noticed at once (`LANPeerConnection` receive loop). Invalid frame length closes the socket.
- iOS reconnects 18 s after a transport failure if still stranded (`armReconnectFallback`).
- Ending a session during a reconnect no longer writes the endpoint back (`reconnectLast`).

**Control macOS**
- Display-switch timeout of 15 s (`DisplayLayoutViewModel.beginDisplaySwitch`). A switch the host confirmed counts as done.
- Clicks on the black bars are dropped; their releases still go through.
- Modifier keys are released when focus leaves the stream (`RemoteStreamNSView.releaseHeldModifiers`).
- Quality changes within 10 s are held and sent when the host accepts them (`ClientSessionCoordinator.sendQualityAdjust`).
- Show All Displays off refreshes the mapping.
- Access button disabled in the App Store edition. Close-app and Forget confirmations. Restore Purchase shows its result. Unlock shows when the Mac is still locked.

**Control iOS**
- Input mapping follows the displayed display: `focusedDisplayOverride` plus `refreshMapping` on selection, layout and stream changes.
- Usage meter stops on idle.
- New video views draw the already-decoded frame (iOS and macOS).
- A failed decoder session is retried on the next keyframe.
- Screenshot status overlay. Display button disabled with one display. Accessibility labels on the session bar.
- Unlock outcome text. Blocked and timeout copy names Vamp Sync and drops the raw "Timeout:" prefix.

**Verification so far**
- `swift test`: 695 passing. This ran before the last edit to `DisplayLayoutViewModel.swift`. That edit passed `swift build` only.
- Xcode Release builds succeeded for VampMiniHost, MacClient and iOSRemote, before the last edit.
- The VampStream build result was not captured.

## Not verified

- Nothing has been run live against the user's Mac, in a simulator, or on a device.
- The Retina capture change has never run on a HiDPI display. A memory note records this: `vamp-retina-display-capture-unverified`.
- Audit findings rest on code reading. Any "medium" or "unverified" item below needs a reproduction before a fix.

## In progress elsewhere

- **Session `harden-session-token-sea`** (`local_3eb5ce15-4bec-4ba2-9223-c25915bbc28d`, proposal `task_325bdc31`) is doing the protocol change for the three gaps below. It must plan with the user before editing.
  - Plaintext session token when the endpoint has no `kapk` (`ClientSessionCoordinator`, sealing block near `offerWasSealed`; host `resolveSessionToken`).
  - No host verification on first contact (`expectedHostFingerprint` empty, answer check skipped).
  - Signaling PSK derived from the public fingerprint (`ConnectionSecurity.deriveKey`); unsigned `kapk` in Bonjour TXT.
- Do not edit those areas without messaging that session first. Review its diff before merging anything.

## Open items, ranked

**Security** (the token session owns the first three)
1. Signaling listener replaces the live signaling connection on any new TCP connect before authentication. `Sources/Discovery/BonjourSignalingService.swift`, `handleIncomingConnection`, about line 277. Keep the existing connection when the newcomer is untrusted.
2. An untrusted offer can release a session in its grace window before the trust gate runs. `HostSessionCoordinator.handleSignalingMessage`, about lines 565-592. Owned by the token session because it touches `handleClientOffer`.
3. Data-port single pending-accept slot has no handshake timeout. `LANPeerConnectionProvider.acceptConnection`, about lines 452-458.
4. Replay cache is FIFO capped at 500, so a flood can evict an entry inside the 30 s window. `BonjourSignalingService.shouldAcceptMessage`.
5. Browser pairing code is not rotated after a successful pair. `HostBrowserControlService.handlePair`, about lines 628-676. The RNG fallback can produce `000000000000` (`generate()`, about lines 135-155). Fix: call `issuePairingCode()` after success, and fail closed on RNG failure.
6. `vamphost://` stop, restart and reject run from any link without confirmation. `HostApp.swift` about lines 616-631, `HostWidgetShared.from(url:)`, `HostAppEnvironment.applyWidgetAction`. The approve path is correctly fingerprint-bound.
7. `PeerTrustGate` fails open to a prompt on store read errors, and approves sessions it could not persist. `Sources/Permissions/PeerTrustGate.swift`, about lines 98-101 and 131-141.
8. Control-message counter is assigned under the lock but sent outside it, so envelopes can arrive out of order and be dropped. `WebRTCSessionManager`, about lines 455-467. The host's watermark check is in `HostInputCommandRouter`, about lines 1064-1076. Fix: serialize counter assignment and send.
9. Legacy watchdog LaunchAgent relaunches Sync about 20-25 s after Quit. Sync shares the Vamp Host bundle ID and never starts `HostProcessHeartbeat`, and the script matches only `*/Vamp Host`. This is a decision for the user: keep the agent, or remove it when Sync launches. Do not uninstall the user's agent without asking.

**Sync host behaviour**
10. A quality change during a pending window switch cancels that switch silently, and the client never gets a result. `handleStreamTargetSwitchRequest` cancels `targetSwitchTask`; `applyRuntimeQualityAdjust` re-targets through the same path, about lines 1683-1687. Fix: do not cancel for a quality re-target, and reply on cancel.
11. Stop and Restart host end a live client session with no confirmation. `VampMiniHostApp.swift`, about lines 1076 and 1519-1524. Fix: confirmation naming the connected client.
12. The input router's serial loop waits on display-switch and multi-display starts, so pings and input stall behind them. `HostInputCommandRouter`, about lines 264-324. Low impact.

**Stability and streaming**
13. Host has no cooldown on keyframe requests. On a constrained link, IDRs queue behind the send backlog faster than it drains. `HostSessionCoordinator.handleKeyframeRequest` (about line 1419). Client `requestKeyframeRefresh` has no debounce (`ClientSessionCoordinator`, about line 1751). Fix: rate-limit host-side IDR requests, except on a decoder error.
14. Decoded-frame `AsyncStream` is unbounded, and its consumer runs on the main actor. `WebRTCSessionManager`, about line 581. Not measured.
15. Client data sockets in `.waiting` burn the full negotiation deadline (15 s on reconnect, 65 s on first connect) before the next candidate.
16. The iOS input flush `CADisplayLink` runs for the whole session, even when idle. `RemoteInteractionViewModel`, about lines 459-473. Battery cost only.

**Control macOS**
17. Resizing on a screen change targets the key window, not the session window. `MacRemoteSessionView`, about lines 875-888 and `resizeWindowToActualSize` (about line 622). Keep a reference to the session window.
18. Possible soft rendering because the display sublayer has no explicit `contentsScale`. `MacVideoStreamView`, about lines 125 and 149. **Unverified**: check on a Retina display before changing it.
19. "Open Tailscale" does nothing when the app is missing, and the return value is discarded. `VampMiniHostApp.swift` about line 1162, `TailscaleDetection.swift` about lines 105-127, `MacHostsScreen.swift` about lines 118-120 and 586-590. Show a message when it returns false.
20. Pairing card dead-ends when there is no Wi-Fi or Ethernet address. `VampMiniHostApp.swift` about lines 1156-1175. Say why instead of showing a blank code.
21. "Forget Saved Assistant" still removes trust in one click. `MacHostsScreen.swift` about lines 421-425. Add a confirmation.
22. The Assistant spinner has no cancel. `MacHostsScreen.swift` about lines 415-416.
23. The "Desktop + Apps" badge may show in View Only builds, because Sync always advertises `supportsDesktopControl`. `HostProductMode.swift` about lines 68-96. **Unverified.**
24. The Sync LINK metric always shows "Tailscale" when Tailscale is detected, whatever path is in use. `VampMiniHostApp.swift` about line 627. **Unverified.**

**Control iOS**
25. Naming decision for the user: iOS calls the Assistant "Vamp Companion", macOS calls it "Vamp Assistant" (`ControlDesign.swift` about lines 21-22).

**Conflicting reports**
- `ClientReconnectCoordinator.swift`: one audit said macOS instantiates it (`MacShellView.swift` about line 36); another said nothing instantiates it. Run `grep -rn ClientReconnectCoordinator` before acting. It reuses a plaintext token (about lines 273-283), so the token session must close that path, either by deleting it or by sealing it.

## Next steps, in order

1. Let the token session finish. Review its diff, then merge only after the user agrees.
2. Run `swift test`, then Xcode Release builds for VampMiniHost, MacClient, iOSRemote and VampStream (`CODE_SIGNING_ALLOWED=NO`), reusing one derived-data path. The `swift build` after the last edit has passed, but the Xcode builds have not run since.
3. Ask the user for a Retina Mac, then verify the display capture size, text sharpness, input placement, and Ultra on a 5K panel.
4. Triage items 1-25 with the user. Start with Sync (items 9-12), since testing them needs the user's Mac.
5. Commit by area, with the attribution line the session specifies at commit time. Do not push without asking.

## Commands

```bash
cd "/Users/m/Desktop/New project 2"
swift test
D=/private/tmp/claude-501/-Users-m--claude-spares-spare-wuYOlF/92eadc48-b481-4fb7-8bf6-8a988bb57cb2/scratchpad/dd
xcodebuild -project RemoteDesktopToolApps.xcodeproj -scheme VampMiniHost -configuration Release -derivedDataPath "$D" CODE_SIGNING_ALLOWED=NO build
xcodebuild -project MacClient.xcodeproj -scheme MacClient -configuration Release -derivedDataPath "$D" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
xcodebuild -project RemoteDesktopToolApps.xcodeproj -scheme iOSRemote -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$D" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
xcodebuild -project VampStream.xcodeproj -scheme VampStream -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$D" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

## Status update (2026-11-21)

Fixed this round, with all four apps building in Release and `swift test` at 735 passing:
- Item 4 (replay cache): live entries are never evicted; past 20,000 new envelopes are refused until old ones age out.
- Item 5 (browser pairing): the RNG fallback now fails closed instead of using zeros. Code rotation after pairing was attempted and reverted: `HostTerminalServiceTests` requires the same code to pair a second browser while it is shown. Decide the intended behaviour, then fix the misleading "one-time" comment.
- Item 6 (vamphost:// stop, restart, reject): the user confirms first.
- Item 7 (PeerTrustGate): fails closed on store read or write errors.
- Item 8 (control counter ordering): counter assignment and send are one step under `controlSendLock`.
- Item 10 (quality change cancels a window pick): a quality re-target no longer cancels a queued pick; superseded picks get a `rejected` reply. A pick already running can still be cancelled by a newer one, silently.
- Item 11 (Stop and Restart): confirmed in the Sync panel and the menu bar.
- Item 13 (keyframe requests): host limit of one per second.
- Item 16 (iOS flush link): stops when nothing is queued.
- Item 18 (Mac resize): only the window that changed screen and shows the stream is resized.
- Item 19 (Tailscale open): says when Tailscale is missing.
- Item 21 (forget Assistant): confirmation added. Item 22 (pairing card): explains why there is no code. Item 22b (Assistant spinner): Cancel added.
- Video layer on Mac: `contentsScale` follows the window's backing scale. Unverified on a Retina display.

Deliberately left open:
- Items 1–3 (signaling listener, untrusted-offer reset, accept-slot timeout): owned by the token-hardening session.
- Item 9 (legacy watchdog LaunchAgent): needs the user's decision.
- Item 12 (serial input loop blocked by display switches): changing the dispatch changes input ordering. Needs a design.
- Item 15 (unbounded decoded-frame stream): changing the buffer could drop keyframes. Needs measurement.
- Item 17 (client waiting sockets): needs device testing.
- Item 20 (Sync LINK metric): needs real transport information. Unverified.
- Item 23 (Desktop + Apps badge in View Only builds): unverified. Check store-build capability gating first.
- Item 25 (naming, Vamp Companion vs Vamp Assistant): user decision.

## Update (2026-11-21, after the handshake change)

- Item 4 (replay cache) was fixed earlier and is still in place.
- Item 2 (session reset before trust): fixed. The release moved into `handleClientOffer`, after the trust decision, and re-checks whether the slot is still held.
- Item 1 (live signaling replaced by any TCP connect): mitigated. A newcomer while a live connection exists is parked and takes over only after a verified message. Any signed message can still take over, because verification proves key possession, not trust. Full protection needs the coordinator to promote only trusted peers. Not done.
- Items 1, 2 and 4 are no longer blocked on the token session.
- ClientReconnectCoordinator is live (MacShellView, MacRemoteSessionView). Its leftovers are still unremoved: `recordConnectionEndpoint`, `onRebuildSignaling`, `lastSessionID`, `lastQualityPreset`.
- Follow-up review (2026-11-21): findings A–D applied. A declined offer leaves the running session's phase, name and settings alone. A new connect is refused while another waits to pair. Each connection has a message allowance.
- Still open from item 1: any validly signed message, from any key, can take over the live signaling connection. Full protection needs promotion for trusted peers only. Per-connection reply routing would also be needed.

## Status update (2026-11-21, final pass)

- Closed as not a defect: item 23 ("Desktop + Apps" in the view-only store build). AGENTS.md defines the store edition as view-only, meaning no remote input. Viewing the desktop is allowed, so the badge is accurate. Changing the wording to "View only" would be a copy decision.
- Done: ClientReconnectCoordinator write-only fields removed (`onRebuildSignaling`, `lastSessionID`, `lastQualityPreset`, `lastHostAddress`, `lastSignalingPort`, `lastHostFingerprint`) and their callers in `MacRemoteSessionView`.
- Open, needs a decision: item 5 (whether a browser pairing code is single-use), item 9 (legacy watchdog LaunchAgent), item 25 (Vamp Companion vs Vamp Assistant naming), and item 1's residual (trusted-only promotion of the live signaling connection).
- Open, needs device or live testing: item 12 (input loop blocked by display switches), item 15 (unbounded decoded-frame stream; the code comment says unbounded is intentional), item 17 (waiting data sockets burn the negotiation deadline).
- Open, needs plumbing: item 20 (Sync link label). It needs the connected peer's address carried from the signaling connection to the Sync panel, and that touches the token session's files.

- Item 1, approved devices only (2026-11-21, token session): the parking protection applies only while the live connection's last verified sender is a device the trust gate approved in this process (`isLiveConnectionProtected`, `trustedPeerFingerprints`). For unapproved devices the latest connection replaces the live one, as before the audit. Known gaps: an unapproved device during its trust prompt can still be displaced by any TCP connect. `trustedPeerFingerprints` is not pruned on revoke until Sync restarts, and a parked newcomer can still promote. Protecting unapproved pairing needs several parked connections with per-connection reply routing.
- Item C (one parked newcomer at a time) applies only while an approved device's session is live, for the same reason.
