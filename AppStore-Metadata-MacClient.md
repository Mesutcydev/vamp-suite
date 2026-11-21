# App Store Connect update — Vamp Control

Existing app: **6778921377** (formerly Vamp : Desktop Control) · Bundle: `com.mesutcy.remotedesktop.macclient`
Version: **2.0.0**, build **63** · macOS 13+ · universal arm64/x86_64

Privacy policy (both update locales): https://thevamp.app/privacy/

Vamp Control ships on the Mac App Store only. The store spec includes `macclient-project.yml` so sources, dependencies, icon, and version/build settings stay shared. The store target adds App Sandbox and uses the existing app identity. Supply the publisher team and explicit distribution profile at archive/export time; no team or credential is stored in the spec.

## Listing copy

Name **Vamp Control**; subtitle, description, promotional text, What's New, and keywords for en-US and tr live in `scripts/apply-vamp-4.0-store-metadata.py` (`--apply` pushes them). Keywords avoid third-party trademarks (the old set used vnc, kvm, and tailscale). The description explains both Vamp Sync editions: the free website edition for keyboard/pointer control and the View Only Mac App Store edition.

In the app, the "Don't have Vamp Sync yet?" card states the same distinction and links to https://thevamp.app/sync/#editions. Review notes in App Store Connect cover build 60, the legacy `com.vamp.desktop.unlimited` purchase, and Tailscale disclosure.

## Release workflow

Archive with `scripts/archive-vamp-app-store.sh control --team TEAM_ID --distribution-profile PROFILE_UUID`. Export with `python3 scripts/export-vamp-sync-app-store.py --product control --archive ARCHIVE_PATH --profile PROFILE_PATH --team TEAM_ID --installer-identity INSTALLER_IDENTITY --output NEW_PKG_PATH`. The exporter verifies the signed package payload, sandbox, identity, and embedded distribution profile before delivery. Upload the verified package to app 6778921377 and attach it to the existing update version.

Retain existing pricing, app categories, reviewer contacts, privacy declarations, and screenshots unless an update is needed. The current binary does not gate features behind purchases. Review notes disclose private Tailscale support; upload or TestFlight processing is not App Store approval.

## Current screenshots

The prior build 58 component compositions have been replaced with captures from the running sandboxed build 59 release app. The App Store-signed archive is preserved for upload. A separate local runtime copy uses ad hoc signing with the same sandbox entitlements because a Mac App Store distribution archive cannot launch directly before Store installation. Its production executable and resources are otherwise unchanged.

Raw window captures are retained under `dist/AppStore/Control-2.3.0-build-59/Screenshots/raw/`. Upload canvases may add localized captions and background padding; the captured app contents must remain intact, preserve their aspect ratio, and show the shipping window chrome, tabs, and scroll state. Do not use the old component renderer for store images. Retain capture evidence and hashes in the release folder.

Frame actual captures with `python3 scripts/render-vamp-control-store-screenshots.py --captures RAW_CAPTURE_DIR --archive ARCHIVE_PATH --output OUTPUT_DIR`. This command only adds captions and padding around complete captured windows; it does not render SwiftUI fixtures.

Build 59 ASC verification: three real images per locale (en-US and tr), all COMPLETE at 1440 × 900 with matching checksums. Active-stream capture remains pending the Sync panel; the current images show discovery and settings only.
