# Contributing

Thanks for helping improve Vamp Terminal.

## Development setup

1. Use macOS 13 or later with Xcode 26 or later. Python 3 is required for the
   Linux companion tests.
2. Build from the active project, `RemoteDesktopToolApps.xcodeproj`; do not
   regenerate or replace it with a stale project copy.
3. Run the core tests:

   ```bash
   swift test
   python3 -m unittest discover -s Tests -p 'test_*.py' -v
   node Tests/BrowserTerminalVTTests.mjs
   ```

4. Build the `MacHost`, `VampTerminalHost`, and `VampTerminalApp` schemes with
   code signing disabled for local verification.
5. Run the unsigned IPA packaging script only when you need a device artifact:

   ```bash
   scripts/package-vamp-terminal-ios.sh --clean --allow-dirty
   ```

## Pull requests

- Keep changes focused and explain their security impact.
- Add tests for protocol, trust, terminal routing, PTY lifecycle, path
  sanitization, clipboard, or reconnect changes.
- Never commit private keys, signing certificates, provisioning profiles, API
  credentials, pairing secrets, or real user logs.
- Do not weaken visible host approval or fingerprint verification for convenience.
- User-facing behavior should remain usable with VoiceOver, keyboard navigation,
  Reduce Motion, Reduce Transparency, and Dynamic Type.
- Update the GitHub Pages preview and documentation for user-visible changes.
- Add a `Signed-off-by` trailer to every commit to certify the
  [Developer Certificate of Origin](DCO.md).

Contributions are accepted under Apache-2.0, as described by the repository
license. The project does not require a copyright assignment.

## AI-assisted contributions

AI tools and coding agents are welcome when they improve a contributor's work,
but a human contributor remains responsible for every submitted line. Review
generated changes, run the relevant tests, verify licenses and provenance, and
describe material AI assistance in the pull request. Agents must follow
[AGENTS.md](AGENTS.md) and must not weaken pairing approval, expose secrets, or
submit speculative security reports without a reproducible technical finding.

## Review and decision process

At least one maintainer approval and passing required checks are required before
merge. Security-sensitive changes should receive review from a maintainer
familiar with the affected trust boundary. Governance and maintainer succession
are described in [GOVERNANCE.md](GOVERNANCE.md).
