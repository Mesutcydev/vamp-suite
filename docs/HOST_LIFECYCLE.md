# Current hosts and discontinued products

As of 3 September 2026, **Vamp Sync and Vamp Assistant are the only current
host apps**. Sync hosts app windows for Control and Stream. Assistant is an
independent AI workspace with its own remote sessions.

Vamp Host, Vamp Terminal Host, and Vamp Linux Host are discontinued. Their
historical source, protocol tests, and build targets remain where needed for
compatibility and shared-source verification. Their presence in source does
not make them supported products. Historical release URLs remain archived;
current website metadata no longer lists the discontinued hosts.

- The macOS host packager defaults to Sync and rejects MacHost and
  VampTerminalHost distribution requests.
- Linux Host packaging is disabled.
- The old Host watchdog supports uninstall only.
- The Terminal client release workflow no longer bundles macOS or Linux hosts.
- Control and Stream remain clients; they are not removed by host cleanup.

## Updating an existing Sync installation

The current public application, bundle, and executable name is **Vamp Sync**.
The stable bundle identifier `com.mesutcy.remotedesktop.host`, scheme
`VampMiniHost`, URL scheme, Keychain identity tag, and legacy data location
remain unchanged. These are compatibility identifiers, not separate products.

Preserve the installed signing identity when updating a locally signed app.
The public ad-hoc package can have a different designated requirement from an
existing certificate-signed installation. Verify the candidate against the
installed app's requirement before replacing it. Use only a valid signing
identity already available and authorized on the installation machine; never
commit certificates, private keys, or a hard-coded personal signing identity.

Do not reset, grant, or edit TCC records to make an update appear compatible.
Existing Screen Recording and Accessibility consent must remain under the
user's control. App data, saved devices, and Keychain entries are preserved.
If the replacement cannot satisfy the existing identity requirements, report
that limitation before making the replacement.
