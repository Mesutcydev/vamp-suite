# Install Vamp Control on iPhone or iPad

Install [Vamp Sync](https://thevamp.app/sync/#download) on the Mac you want to
reach. When a [Vamp Control IPA](https://thevamp.app/#download-control-ios) is
available, download it and its SHA-256 checksum.

1. Run `shasum -a 256` on the IPA and compare the complete hash with the published
   checksum.
2. Import the unsigned IPA into AltStore, SideStore, Sideloadly, or your own
   signing workflow. Re-sign with an Apple ID or team you control.
3. Allow Local Network access when prompted by Vamp Control.
4. Pair over a trusted LAN or private Tailscale network. Compare the complete
   device fingerprint on both devices before approving the request in Vamp Sync.

Sync needs Screen Recording to share video. The website edition also needs
Accessibility for keyboard and pointer control.
