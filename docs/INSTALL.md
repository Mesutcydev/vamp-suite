# Install Vamp

Start with [the current downloads](https://thevamp.app/#download). Install
**Vamp Sync** on the Mac you want to reach, then **one client** on your other
device. [Compare Control and Stream](https://thevamp.app/#families).

## 1. Install Sync on your Mac

1. Download the Sync DMG and its `.sha256` file. The current direct build is for
   Apple Silicon and macOS 13 or later.
2. In the download directory, verify the file:

   ```sh
   shasum -a 256 -c VampSync-macOS-<version>-build-<number>-adhoc.dmg.sha256
   ```

3. Drag **Vamp Sync** to `/Applications` and open it. If macOS blocks the direct
   build, use **System Settings → Privacy & Security → Open Anyway** after
   verifying its source. Do not disable Gatekeeper globally.
4. Open Sync in the menu bar. Grant **Screen Recording** for video and
   **Accessibility** for keyboard and pointer control, using the app identity
   shown by macOS. Refresh Sync’s permission status afterward.

Run only one macOS host at a time. If you previously used a different Vamp host,
quit it before starting Sync. Different hosts have separate device identities
and trust stores; approve a new pairing only after verification.

## 2. Install one client

| Your other device | Choose |
| --- | --- |
| Mac | **Vamp Control for macOS**, Apple Silicon, macOS 13+ |
| iPhone or iPad | **Vamp Control** for the Control interface, or **Vamp Stream** for a focused app-window experience |

For Control on Mac, download the ZIP and checksum, verify it, extract it, and
move Vamp Control to `/Applications`. Follow the same first-launch process as
Sync. For iOS, use the [sideloading guide](IOS_SIDELOAD.md); the IPAs must be
re-signed before installation.

## 3. Pair and open an app

Use the same trusted LAN or a private Tailscale network. Open the client and
scan Sync’s QR or use its pairing link. Compare the **complete device
fingerprint** on both devices before approving on the Mac. Then choose a Mac
app window. Both clients support Sync’s app-window connection.

Keep host ports private; do not forward them to the public internet.

## Optional: Vamp Assistant

Assistant is an independent AI workspace with its own remote companions. It
does not require Sync.

1. Download the [Assistant Mac app](https://thevamp.app/assistant/#download)
   and its checksum. It requires Apple Silicon and macOS 15+.
2. Run `shasum -a 256 <download>.dmg` and compare the complete hash with the
   downloaded `.sha256` file. Some Assistant releases provide only the hash,
   without a filename, so `shasum -c` is not supported for those checksum files.
3. Move Assistant to `/Applications`, open it, and choose a local model or add
   your own provider key.
4. If you want remote access, enable **Remote Sessions** and pair its iOS or
   browser companion after verifying the displayed code or device identity.

Stream can optionally connect directly to Assistant’s Remote Sessions for an
app window or full display. That pairing is separate from Sync.

## Build from source

Use macOS, Xcode 26 or later, and XcodeGen:

```sh
scripts/package-vamp-stream-ios.sh --clean
scripts/package-vamp-mini-host.sh --clean
```

Release packaging requires a clean Git tree. Add `--allow-dirty` only for a
local development artifact. Outputs are written to `dist/VampStream/` and
`dist/VampStreamHost/`.

The Sync scheme and bundle ID retain `VampMiniHost` and
`com.mesutcy.remotedesktop.host` for compatibility. The app name is Vamp Sync.
Specialist Terminal and Linux instructions remain in their own guides.
