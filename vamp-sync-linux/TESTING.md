# Linux compatibility and diagnostics specification

## Automated checks

Run the wire, trust, replay, TLS, encoder and diagnostics tests with:

```sh
go test -race ./...
go vet ./...
```

For the GTK panel smoke test, install the GUI dependencies in [the build guide](README.md) and run `xvfb-run -a /usr/bin/python3 desktop/test_panel.py`. The test checks the ready, approval, and streaming states and requires an exact fingerprint before enabling approval.

For the Linux integration test, install `xvfb`, `xauth`, `openbox`, `xterm`, `xclip`, and FFmpeg in a disposable test environment:

```sh
xvfb-run -a sh -ec 'openbox >/tmp/vamp-test-wm.log 2>&1 & VAMP_TEST_X11=1 go test -race ./...'
```

This test exercises the real Linux X11 capture and XTEST backends, pairing with a synthetic device, secure control, app browsing, video, data-socket reattachment, and clipboard round trips. The disposable X server has no logind seat. Verify lock behavior on a real logged-in Xorg desktop.

The fixtures in `testdata` contain a synthetic P-256-signed offer encoded by the existing Swift signaling models and an application-list control packet generated with CryptoKit. The fixture key and payload are public test values.

## Physical-device release matrix

Test the current Vamp Control and Vamp Stream builds on an iPhone and iPad. Record the client version/build, iOS or iPadOS version, Linux distribution, desktop/window manager, host commit, and connection path. Run a session to the macOS Sync host with the same client builds as a baseline. Mark each applicable check Pass, Fail, or Untested. Mark unsupported features separately.

| Area | Actions and expected outcome |
| --- | --- |
| LAN discovery | Start with `--discover`; find the Linux host, confirm the fingerprint and connect. Add the same host manually and repeat after restarting the client. |
| Tailscale | Connect by private IPv4 with both devices on the same tailnet. Disconnect Tailscale and confirm the private address becomes unreachable. |
| Pairing | Compare both fingerprints. A mistyped fingerprint and a denial must leave video and input unavailable. Correct approval allows the session. Restart the host, reconnect, revoke, and check that a new approval is required. |
| Desktop | From Control, confirm the first frame and full desktop geometry. Test a tap at each edge, physical keyboard, scroll, drag, relative pointer, rotation, and quality change. Compare text and key behavior with the Linux keyboard layout. |
| App windows | From Stream, check that the app browser loads before capture. Select a window, cover it locally with a second app, and verify that the second app never appears in the stream or receives remote input. Switch windows, resize, return to original proportions, then close the selected window. Return to the app list and verify that capture stops. Add an app with `--app`, confirm it appears while closed, and launch it from Stream. |
| Clipboard | Enable `--clipboard`, copy short Unicode text in both directions, and repeat while disabled and while locked. Clipboard changes must stop when the opt-in or desktop is unavailable. |
| View Only | Repeat a desktop and app session without `--control`. Viewing and switching work. Pointer, keyboard, app activation, resize, and close commands are blocked. |
| Lock and focus | Lock the Linux desktop or switch to a different login session. The stream stops and no new input reaches the screen. Unlock locally and reconnect. In app mode, focus another app and verify that it cannot receive remote keyboard input. |
| Recovery | Disconnect the network, background and resume the iOS app, and restart the host. Reconnect using saved trust. Drop a session during a held drag and verify the host releases the button. |
| Busy host | Start a second client while a session is active. The second client must not take over the first client's capture. |
| Diagnostics | Reproduce a failure, export a report, and confirm that its timestamps, attempt number, event codes and counters reconstruct the failing stage. |

## Tester handoff

For every failed case, record the case name, expected and observed results, smallest reproduction steps, approximate time and time zone, and whether it repeats. Attach the host report from **Export diagnostics…** in the panel settings or `diagnose` in the terminal. Include the iOS app's debugger export if the build exposes one, after reviewing it for private information. Do not attach the host state directory, keys, pairing data, real window contents, or input text.

## Report format, version 1

The report is UTF-8 JSON. It is written only on local request, with mode `0600`. No automatic upload occurs. The host keeps the latest 512 events in memory. Restarting clears the ring and resets attempt numbers. Export before quitting if the failure is intermittent.

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Integer report format version. |
| `version`, `os`, `architecture` | Host version and build platform. |
| `startedAt`, `exportedAt` | UTC ISO 8601 wall clock timestamps. |
| `inputEnabled`, `clipboardEnabled`, `discoveryEnabled` | Local runtime flags. |
| `droppedBreadcrumbs` | Number of older events overwritten by the ring. |
| `breadcrumbs` | Events in strictly ascending `sequence` order. |
| `sequence`, `at`, `elapsedMs` | Event sequence, UTC time, and elapsed monotonic milliseconds. |
| `attempt` | Local, process-scoped connection number. Global events omit it. |
| `event`, `value` | Fixed event code and optional integer measurement. |

| Event group | Codes and measurements |
| --- | --- |
| Host, discovery and desktop | `host.ready`, `discovery.started`, `discovery.failed`, `discovery.stopped`, `desktop.available`, `desktop.unavailable`, `desktop.blocked` |
| Signaling | `signal.accepted`, `signal.tls_ready`, `signal.tls_failed`, `signal.invalid`, `signal.key_sent`, `signal.key_failed`, `signal.offer_verified`, `signal.offer_invalid`, `signal.token_rejected`, `signal.answer_sent`, `signal.answer_failed` |
| Trust | `pair.pending`, `pair.approved`, `pair.denied`, `pair.expired`, `pair.abandoned`, `pair.trusted`, `pair.revoked`, `pair.fingerprint_mismatch`, `pair.storage_failed` |
| Transport | `data.bind_failed`, `data.tls_ready`, `data.tls_failed`, `data.connection_failed`, `data.awaiting_reattach`, `data.read_ended`, `data.command_failed`, `control.authenticated`, `control.timeout`, `control.rejected` (total), `session.busy`, `session.replaced`, `session.closed` |
| Inventory and capture | `inventory.ready` (window count), `inventory.failed`, `capture.starting`, `capture.start_failed`, `capture.display_failed`, `capture.first_frame_failed`, `capture.ready`, `capture.reattached`, `capture.launch_requested`, `capture.launch_failed`, `capture.resize_requested`, `capture.close_requested`, `capture.returned_to_browser`, `capture.target_rejected`, `capture.ended` |
| Video and input | `video.first_frame` (wire bytes), `video.frames_sent` (total sequence count), `video.quality_changed`, `video.keyframe_requested`, `video.write_failed`, `input.accepted` (total), `input.rejected` (total) |
| Clipboard | `clipboard.updated`, `clipboard.sent`, `clipboard.failed` |
| Diagnostics | `diagnostics.export_requested` |

Correlation uses attempt numbers. A run ending before `signal.offer_verified` narrows the failure to discovery, signaling, or key exchange. An approved request followed by `data.connection_failed` indicates that no eligible data socket finished its TLS-PSK handshake. `capture.first_frame_failed` indicates an X11 or encoding failure before the first keyframe. After `video.first_frame`, compare the client-side playback or decoder events.
