# Install Vamp Sync and Vamp Control

Install **Vamp Sync** on the Mac you want to reach. Install **Vamp Control** on
the Mac, iPhone, or iPad you’ll use to connect.

## 1. Install Vamp Sync

1. Get the DMG and its SHA-256 checksum from the [download page](https://thevamp.app/#download).
   The direct Sync build supports Intel and Apple Silicon Macs on macOS 13 or later.
2. Run `shasum -a 256` on the DMG and compare the complete hash with the published checksum.
3. Open the DMG, move **Vamp Sync** to Applications, and open it. If macOS
   blocks a verified direct build, choose **Open Anyway** under
   **System Settings → Privacy & Security**.
4. Open Sync in the menu bar. Grant **Screen Recording** for video. The website
   edition also needs **Accessibility** for keyboard and pointer control.

## 2. Install Vamp Control

Choose your device under [Vamp Control](https://thevamp.app/#control).

- **Mac** · Verify the download checksum, then move Vamp Control to
  Applications. The direct build requires Apple Silicon and macOS 13 or later.
- **iPhone or iPad** · When an IPA is available, follow the
  [sideloading guide](IOS_SIDELOAD.md).

## 3. Pair your devices

1. Choose Local Wi-Fi or Tailscale in Vamp Sync. Use a trusted local network or
   your private Tailscale network on both devices.
2. Use the pairing QR code or link in Vamp Control.
3. Compare the **complete device fingerprint** on both devices before approving
   the request on the Mac. Then choose an app window in Vamp Control.

Run only one host on your Mac at a time. Keep host ports private.
