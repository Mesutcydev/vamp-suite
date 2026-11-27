# Security Policy

## Supported versions

| Version | Supported |
| --- | --- |
| Latest `2.x` release | Yes |
| Earlier releases | No |

Security fixes are applied to the current release line. Users should run the newest
published build and verify its checksum and release manifest.

## Reporting a vulnerability

Do not open a public issue for a vulnerability that could expose a screen, terminal, clipboard, files, credentials, or pairing identity.

Email **security@mesut.uk** with:

- affected version and macOS version;
- host/client topology and whether a VPN was involved;
- clear reproduction steps;
- expected and observed behavior;
- logs with personal data, addresses, fingerprints, and secrets removed.

The maintainers aim to acknowledge a complete report within 7 calendar days, provide
an initial assessment within 14 days, and send progress updates at least every 14
days while remediation is active. Timelines may change with severity and complexity;
the reporter will be told when that happens.

If email is unavailable, open a private GitHub Security Advisory in the repository.
Do not include exploit details in a public issue.

## Scope

Reports about authentication, pairing, transport security, input injection, terminal
access, clipboard or file transfer, update integrity, path traversal, secret exposure,
or denial of service are in scope. Social engineering, physical access to an already
unlocked Mac, and attacks requiring the reporter to weaken macOS security controls
are generally out of scope unless they expose a separate product flaw.

Good-faith research that avoids privacy violations, data destruction, persistence,
service disruption, and access to systems without permission is welcome.

## Trust model

- Only control Macs you own or are authorized to access.
- A new peer identity requires visible host approval.
- Verify the displayed fingerprint out of band before an agent approves it.
- Terminal mode is opt-in on Vamp Host and should remain off when unused. It is always on for Vamp Terminal Host, Vamp Linux Host, and Safari.
- Vamp Sync and Vamp Control website builds are signed with a Developer ID, notarized by Apple, and
  update through Sparkle with an EdDSA signature on every download. Older Vamp Host and Terminal
  Host website builds were ad-hoc signed and cannot provide notarization assurance. Verify the
  published SHA-256 checksum, or build from source.
- The data channel between updated apps uses TLS 1.2 ECDHE-PSK (ChaCha20-Poly1305), so a recorded
  session stays unreadable even if its session token leaks later. An older app, an older Mac or the
  Linux host negotiates the previous suite instead and still connects, without forward secrecy.
- A new Vamp Sync install refuses apps that predate the signed key exchange (their session token
  crosses the network unsealed). A Mac that already had paired devices keeps accepting them. Either
  way, a session on the older handshake never gets shells, agent runs or Remote Unlock, and the choice
  is in the menu under Allow Older Vamp Apps.
- The Vamp Assistant compatibility endpoint (port 9575) speaks plain HTTP. On a shared network
  anyone can read its pairing code, token and traffic. Use it over Tailscale, which encrypts the
  link. The apps carry no App Transport Security exception: the Assistant client uses its own
  Network.framework HTTP client, which never follows a redirect. Vamp Control sends the Mac login password (Remote Unlock) without asking only over a
  Tailscale or HTTPS address; on the Assistant's LAN fallback it says the connection is not encrypted
  and asks before sending it.
- Terminal Mode is a per-Mac setting that an in-place update of the old Vamp Host carries over to
  Vamp Sync, and Vamp Sync's menu-bar menu shows it as "Terminal Mode" with a check mark. If you do not use
  the Safari terminal or Chat, switch it off there (or quit Vamp Sync and run
  `defaults write com.mesutcy.remotedesktop.host com.remotedesktop.host.terminalModeEnabled -bool false`).

## Disclosure and credit

The project follows coordinated disclosure. Maintainers will work with reporters on a
reasonable publication date after a fix is available. Reporters are credited in the
release notes unless they request anonymity.

## Hardening switches

These are read from the Mac's preferences (`com.mesutcy.remotedesktop.host`) and change nothing
unless set:

| Key | Effect |
| --- | --- |
| `com.remotedesktop.host.acceptLegacyClients` = `false` (menu: Allow Older Vamp Apps) | Refuse apps that predate the signed key exchange. Their session token crosses the network unsealed, so anyone who reads it can take that session. Set it once every device is updated. |
| `com.remotedesktop.host.browserAllowedHosts` = array of names | Serve the Safari terminal under extra Host names. Loopback, IP addresses, single-label names, `*.ts.net` and `*.local` are served by default; a custom domain must be listed (`example.test` exact, or `.example.test` for a suffix). |
