# Vamp Sync for Linux

Native Linux host for Vamp Control and Vamp Stream. Control clients that request desktop mode receive the X11 desktop. Stream opens the app browser and begins capture when a window is selected. Linux uses X11 and XComposite for capture, XTEST for input, FFmpeg for H.264, and Avahi for discovery. It implements the existing Vamp signed signaling, pairing and encrypted data protocol.

## Install the desktop app

Extract the installer ZIP and run `./install.sh` on Debian 12, Ubuntu 24.04,
or a newer compatible release. The archive includes amd64 and arm64 packages.
Open **Vamp Sync** from the app menu or run `vamp-sync`. The host runs as your
regular desktop user.

## Build and open the panel

Install Go 1.24 or newer. On Debian or Ubuntu, install the native dependencies:

```sh
sudo apt-get install build-essential pkg-config libssl-dev libx11-dev libx11-xcb-dev \
  libxcb-composite0-dev libxcb-xtest0-dev libxcb-screensaver0-dev \
  ffmpeg avahi-daemon avahi-utils \
  python3-gi gir1.2-gtk-3.0 qrencode iproute2
cd vamp-sync-linux
go build -o build/vamp-sync-linux .
./vamp-sync
```

The GTK panel follows Vamp Sync on macOS, including its branded backdrop,
pairing QR code, host fingerprint, stream status, access controls, trusted
devices, and settings menu. Click **Start host**, then choose a private network
in the pairing card. Use the **Remote control** switch to grant remote input.
The panel can hide in the tray on desktops that support it. Other desktops keep
it available in the taskbar. The settings menu offers **Export diagnostics…**.

For terminal-only operation, run the following from an active Xorg login as
your desktop user. Replace the address with one assigned to the Linux machine
on your private LAN.

```sh
./build/vamp-sync-linux --bind 192.168.1.20 --discover --control
```

`--control` enables remote mouse and keyboard, app activation, resizing, and polite close requests for paired devices. Omit it for View Only. The host requires systemd-logind, an active local X11 login, and the X11 Screen Saver extension. Window lists work with an EWMH window manager. The default bind address is IPv4 loopback. For a Tailscale connection, bind the IPv4 address assigned to `tailscale0`, omit `--discover`, and add that address manually in Vamp. Use a LAN or private tailnet. Do not forward ports at the router.

To enable app launch, install `gtk-launch` (from `libgtk-3-bin` on Debian and
Ubuntu) and add one `--app 'desktop-id,WM_CLASS,Display Name'` flag for each
application you want to allow. Use its installed desktop entry ID and the class
reported by `xprop WM_CLASS` when you click its running window. To opt in to
plaintext clipboard sharing, install `xclip` and add `--clipboard`. Both
features require `--control`.

1. In Vamp Control or Stream, pick the host or enter its address on port `9471`.
2. Compare the host fingerprint displayed in the client with the Linux terminal before accepting it.
3. Compare the phone or tablet fingerprint displayed in Vamp with the pending fingerprint in the Linux terminal. Type `approve <full-fingerprint>` only after they match. Type `deny` to decline.
4. In Stream, select a running app window. In Control, select the desktop or a window if the client offers that picker.

Signaling uses `9471`, with TLS-PSK on `9473` for clients that discover it. The session data connection on `9472` requires the sealed per-session key. The host supports one active device at a time.

Local commands are `status`, `approve <fingerprint>`, `deny`, `disconnect`, `revoke <fingerprint>`, `diagnose`, and `quit`. The identity and approved fingerprints live in the private state directory under `${XDG_CONFIG_HOME:-$HOME/.config}/vamp-sync-linux`. The terminal command runs in the foreground and stops when its terminal closes. The panel manages its host until you choose **Stop host** or **Quit Vamp Sync**.

## Compatibility and scope

| Capability | Linux behavior |
| --- | --- |
| Desktop and app streaming | H.264 SDR at up to 24 fps. Desktop uses one X11 root surface. App capture uses the selected window's backing pixmap. |
| Discovery and pairing | Avahi on LAN, manual LAN or Tailscale address, mutual identity verification, persistent pairing, revoke and reconnect. |
| Remote input | Pointer movement, buttons, dragging, scrolling, physical keys and text representable by the current X11 keyboard layout. App input requires the appropriate focus or pointer target. |
| Window management | Lists open windows, launches configured apps, activates windows, requests adaptive or original sizing, and requests normal close when the application supports it. The window manager can constrain requests. |
| Desktop permission | Active-session and screen-saver checks gate capture and input. Locking or losing the X11 session ends the stream. |
| Clipboard | Optional plaintext copy and paste over the authenticated channel. |
| Unsupported surfaces | Native Wayland and headless sessions, Remote Unlock, file transfers, audio, HDR, individual monitor selection, and Terminal Mode. |

Protocol and headless Linux tests exercise the wire and X11 pipeline. The [tester specification](TESTING.md) defines the physical-device release checks for Control and Stream.

## Reports

After reproducing a problem, type `diagnose` in the Linux console. Attach the named `vamp-sync-linux-diagnostics-*.json` file and the reproduction details in [TESTING.md](TESTING.md). The local ring buffer uses fixed event codes with counts and timing. It excludes source IPs, names, fingerprints, pairing secrets, terminal or input text, and captured content.
