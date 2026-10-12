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
- Website binaries are ad-hoc signed and cannot provide Apple notarization assurance. Verify the published SHA-256 checksum, or build from source.

## Disclosure and credit

The project follows coordinated disclosure. Maintainers will work with reporters on a
reasonable publication date after a fix is available. Reporters are credited in the
release notes unless they request anonymity.
