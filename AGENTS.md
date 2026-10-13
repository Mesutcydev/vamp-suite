# AGENTS.md — Vamp

This file is the operational contract for AI agents working with the Vamp suite.

## Product

Vamp is an open-source remote desktop and app-streaming suite. Its active apps are
Vamp Sync, Vamp Stream, and Vamp Control on macOS and iOS/iPadOS. They reuse the
signed pairing, trust, Tailscale, and authenticated WebRTC stack in this
repository. Vamp Assistant remains a separate compatibility endpoint. Vamp Host,
Vamp Terminal Host, Vamp Terminal, and Vamp Linux Host are discontinued;
historical sources and identifiers remain for compatibility and shared-source
verification. Do not package, reinstall, or advertise discontinued products.

| Component | Value |
| --- | --- |
| Full host | `Vamp Host` — discontinued; historical full host |
| Light host | `Vamp Terminal Host` — discontinued |
| Mini host | `Vamp Sync` — active Mac desktop/app host for Control; app-window host for Stream |
| Linux host | `Vamp Linux Host` — discontinued |
| Remote-desktop client | `Vamp Control` — macOS and iOS/iPadOS. Terminal Mode is an overlay |
| Terminal client | `Vamp Terminal` — discontinued; Terminal Mode remains in Vamp Control |
| App-stream client | `Vamp Stream` — focused iOS/iPadOS app-window streaming client |
| Assistant compatibility | `Vamp Assistant` — separate compatibility endpoint on private port `9575` |
| Browser client | Safari control on host loopback `9475` |
| Full host bundle ID | `com.mesutcy.remotedesktop.host` |
| Light host bundle ID | `com.mesutcy.remotedesktop.terminalhost` |
| Mini host bundle ID | `com.mesutcy.remotedesktop.minhost` |
| Control macOS bundle ID | `com.mesutcy.remotedesktop.macclient` |
| Control iOS bundle ID | `com.mesutcy.remotedesktop.ios` |
| Terminal iOS bundle ID | `com.mesutcy.remotedesktop.terminal` |
| Stream iOS bundle ID | `com.mesutcy.remotedesktop.stream` |
| Project | `RemoteDesktopToolApps.xcodeproj` |
| Full host scheme | `MacHost` |
| Light host scheme | `VampTerminalHost` |
| Mini host scheme | `VampMiniHost` |
| iOS terminal scheme | `VampTerminalApp` |
| Stream project/spec | `vampstream-project.yml` / `VampStream` |
| Bonjour service | `_screenharbor._tcp` (wire-compatibility contract only) |
| Signaling ports | `9471` plain, `9473` TLS |
| Data port | `9472` |
| Browser control | loopback `9475`, exposed privately with Tailscale Serve |
| URL scheme | `vamphost://action/{start,stop,restart}` and `vampterminalhost://` |
| Mini URL scheme | `vampminihost://` |
| License | Apache-2.0 |

Run only one macOS host at a time. Vamp Control cannot attach to Vamp Linux Host.

The website iOS builds are unsigned device IPAs for AltStore-style re-signing. No
project-owned Apple team, certificate, provisioning profile, App Store Connect
account, hosted relay, or public port forwarding is required.

Store distribution uses `VampSyncAppStore` in `project.yml` and the
`VampStreamAppStore` scheme / `AppStore` configuration in `vampstream-project.yml`.
Store app display names are App Sync (macOS) and App Stream (iOS/iPadOS);
retain the existing bundle IDs, wire names, storage paths, and internal schemes.
Keep website and store sources and version/build settings shared. Sync's store
edition is sandboxed and View Only: no Accessibility request, remote input,
Remote Unlock, window resize, app launch/close, terminal execution, or Sparkle.
Both Stream editions connect to the user's own Mac over a physical LAN or a
private Tailscale network. Store connections validate the resolved address and
require an active Tailscale tunnel for tailnet peers. Preserve pairing, TLS,
redirect restrictions, and Sync's View Only policy. App Review 4.2.7 still
specifies LAN for focused streaming clients; disclose Tailscale honestly in
review notes and do not claim that a TestFlight upload confirms Store approval.
Signed store archives require the publisher's team supplied at build time;
never hard-code a team or credential. See `AppStore-Metadata-Vamp.md` and
`scripts/archive-vamp-app-store.sh` for the release path.

## Build

MacHost, VampTerminalHost, and VampTerminalApp remain historical shared-source
verification targets, not maintained products or distribution paths.

SwiftTerm is pinned to 1.18.0 in every spec. 1.19.0 added a build-tool plugin whose
`SwiftTermBuildInfoGenerator` is a macOS host executable that Xcode cannot place for an
iOS destination, which breaks every iOS build. Do not loosen the pin without checking
that an iOS build still succeeds.

```bash
swift test

xcodegen generate --spec project.yml

xcodebuild -project RemoteDesktopToolApps.xcodeproj -scheme VampMiniHost \
  -configuration Release CODE_SIGNING_ALLOWED=NO build

xcodebuild -project RemoteDesktopToolApps.xcodeproj -scheme iOSRemote \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

xcodegen generate --spec vampstream-project.yml
xcodebuild -project VampStream.xcodeproj -scheme VampStream \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

xcodegen generate --spec macclient-project.yml
xcodebuild -project MacClient.xcodeproj -scheme MacClient \
  -configuration Release CODE_SIGNING_ALLOWED=NO build
```

Package the active iOS app and Mac host with:

```bash
scripts/package-vamp-stream-ios.sh --clean --allow-dirty
scripts/package-vamp-mini-host.sh --clean --allow-dirty
```

Do not add a hard-coded Apple team or private credential to the public project.

## Agent CLI

The repository includes the `vamp` wrapper. After installing Vamp Host, agents
can use:

```bash
vamp ensure
vamp status --json
vamp pending --json
vamp approve-pairing --fingerprint <verified-hex>
vamp terminal list
vamp terminal start --session work
vamp terminal attach work
vamp terminal agent opencode --session opencode
vamp terminal agent claude --session claude
vamp terminal agent codex --session codex
# also: pi, commandcode, chatgpt, kimi, qwen, aider, grok, gemini
vamp browser serve
```

The CLI exits with `0` for success, `1` when the host is not installed, `2` when
it is installed but not advertising, `3` when human permissions are required,
`4` for invalid usage, `5` when no trust request is pending, `6` when a trust
action did not resolve, `7` for a fingerprint mismatch, and `8` on timeout.

## Non-negotiable safety

- Never approve a pairing or connection request merely because it exists.
- Show the user the pending device name and fingerprint and require an exact,
  independently verified fingerprint before approving.
- Never bypass Screen Recording or Accessibility consent. These permissions are
  granted by the user in System Settings for the specific installed host.
  Preserve the bundle identifier, signing identity, data, and existing grants
  during updates; never reset or edit TCC permissions to force continuity.
- Never expose host or browser ports directly to the public internet. Use a
  trusted LAN or private Tailscale network.
- Do not commit private keys, certificates, provisioning profiles, API
  credentials, pairing secrets, or real user logs.
- Terminal-only mode must reject display, pointer, keyboard, microphone, and
  file-transfer commands.

## Persistent sessions (architecture contract)

- A transport disconnect is an ATTACHMENT event, never a session event.
  Transport loss marks the session detached (`HostTerminalService`); it must
  never tear down PTYs, agent processes, or task state.
- The Mac is authoritative. `HostSessionRegistry` (session/terminal metadata)
  and `HostSessionJournal` (bounded semantic event history with monotonic
  sequences) persist under `<App Support>/<Product>/sessions` and `…/journal`
  and survive app restarts. Reconnects reattach to the same PTYs by stable
  session/terminal IDs and replay missed semantic events via the
  SESSION_SYNC_REQUEST/SNAPSHOT/SYNC_EVENT data-channel protocol.
- Raw terminal bytes must NEVER be persisted to disk. They live only in the
  bounded in-memory reattach buffer in `HostTerminalService`.
- Semantic events carry monotonic journal sequences; clients dedupe by
  sequence. Never weaken sequence validation or dedupe logic.
- Explicit teardown paths are: per-tab close, Terminal Mode disabled, host
  quit, and detached-retention expiry. Everything else detaches.

## Source map

- `Sources/HostApp`: full host, light host mode, terminal PTY service, and Safari control
- `Sources/HostApp/VampMiniHostApp.swift`: standalone menu-bar pairing and permission surface
- `Sources/ClientiOS`: shared iOS connection services for Vamp Control and Vamp Stream
- `Sources/SharedProtocol`: versioned wire messages and terminal routing
- `Sources/SharedModels`: capability metadata and shared session models
- `Sources/TransportWebRTC`: signed signaling and data transport
- `Sources/Permissions`: host permission and distribution policy
- `linux-host`: dependency-free Safari/WebSocket host
- `scripts/vamp`: agent CLI wrapper
- `scripts/package-vamp-terminal-ios.sh`: historical unsigned iOS packaging; do not distribute
- `docs/index.html`: GitHub Pages product site
- `docs/sync/index.html`: Vamp Sync product page

## Verification

For protocol, trust, terminal routing, or PTY changes, run `swift test` and the
Linux host tests. Build the four active app targets (Vamp Sync, Vamp Stream,
Vamp Control iOS, and Vamp Control macOS) after shared-source changes. Verify
the IPA checksum and manifest before sideloading.

Never weaken pairing approval, replay protection, session-ID validation, or
terminal-ID validation for convenience.
