# Vamp store releases

Vamp Sync and Vamp Stream have store build variants named App Sync and App Stream using the same sources and version settings as their website builds. This document contains listing copy and the remaining release steps. Store publication requires the publisher's own Apple Developer account; no team or credentials are stored in the project.

Both products use version **1.0**, build **1** for the initial store release; these values are shared in their product specs. The bundle IDs stay unchanged.

## Builds and future updates

Sync's `VampSyncBase` template in `project.yml` owns its sources, dependencies, version, and build number. `VampMiniHostApp` adds Sparkle for website updates; `VampSyncAppStore` adds App Sandbox and removes the external updater. Both keep `com.mesutcy.remotedesktop.minhost`. Run only one Sync installation at a time. Store storage is containerized; moving between channels can require pairing again. Do not reset TCC or copy trust keys automatically.

In Sync's pairing panel, choose **Local Wi-Fi** for devices on the same trusted network or **Tailscale** for devices on the same private tailnet. Each option has its own QR address; the presence of Wi-Fi does not override a Tailscale selection. Tailnet pairing uses the numeric Tailscale IPv4 address, so MagicDNS is optional. The sandboxed Store edition detects an active Tailscale tunnel through network interfaces and never launches the external CLI. Network choice does not change View Only restrictions or approve a device.

Stream uses one target in `vampstream-project.yml`: Release produces the website build and AppStore produces the App Store build. Both keep `com.mesutcy.remotedesktop.stream` and the same version/build values. Both editions support trusted Wi-Fi/Ethernet and private Tailscale for Sync, Assistant, and Companion connections, including reconnects. The AppStore configuration validates each resolved address and requires an active Tailscale tunnel for tailnet destinations. Public addresses and redirects remain blocked.

Change shared code once, increment each product's version/build in its shared spec once, then build both channels from the same commit. CI compiles both editions and checks the store bundles. Apple releases still require review; publishing a website update cannot automatically install a store update.

```bash
# Unsigned archive verification; these archives cannot be uploaded.
scripts/archive-vamp-app-store.sh all --unsigned

# Signed archives using your locally configured signing assets.
scripts/archive-vamp-app-store.sh all --team YOUR_TEAM_ID
```

Open the signed archives in Xcode Organizer to validate and upload. Use an Xcode release accepted by Apple. Website packaging continues through `scripts/package-vamp-mini-host.sh` and `scripts/package-vamp-stream-ios.sh`; never distribute the store archive through the website updater.

## App Sync listing

- Name: App Sync
- Subtitle: Share your Mac app windows
- Category: Utilities
- Bundle: `com.mesutcy.remotedesktop.minhost`
- Minimum OS: macOS 14
- Marketing URL: https://thevamp.app/sync/
- Support URL: https://github.com/Mesutcydev/vamp-suite/issues
- Privacy URL: https://thevamp.app/privacy/
- Keywords: screen sharing,app windows,stream,mac,private,companion,view

Description:

App Sync shares app windows from your Mac with your paired iPhone or iPad running App Stream, or with Vamp Control. Choose a window already open on your Mac and view it over your private network. Approve each new device on the Mac after comparing its complete fingerprint, and revoke access from the menu bar whenever you need to.

The Mac App Store edition runs in View Only mode. Screen Recording permission is needed to share video. It does not request Accessibility permission, inject keyboard or pointer input, resize windows, launch or close other apps, or remotely unlock your Mac. Open and arrange windows on the Mac before sharing them. Updates are provided by the Mac App Store.

App Sync does not require a Vamp account or a hosted relay. App Stream connects to your own Mac over trusted Wi-Fi/Ethernet or a private Tailscale network. A receiving App Stream or Vamp Control client is required to view a stream.

Review notes:

This is the sandboxed Mac companion, with no external updater or helper installation. Its existing-window capture uses ScreenCaptureKit after user consent. Accessibility-based window management and input injection are disabled by the host's enforced View Only policy. The website edition has broader controls and is described in the app's edition information; those controls are unavailable in this submitted build.

For review, open a TextEdit window on a Mac running Sync, grant Screen Recording through System Settings, and pair a client on the same LAN. Compare the full fingerprints before approval. Stop/start sharing, select a different existing window, and revoke the paired client from Sync's menu-bar panel. No test account, payment, license key, or public server is needed.

## App Stream listing

- Name: App Stream
- Subtitle: Your Mac apps on iPhone & iPad
- Category: Productivity
- Bundle: `com.mesutcy.remotedesktop.stream`
- Minimum OS: iOS/iPadOS 18
- Marketing URL: https://thevamp.app/stream/
- Support URL: https://github.com/Mesutcydev/vamp-suite/issues
- Privacy URL: https://thevamp.app/privacy/
- Keywords: mac,app streaming,screen sharing,private,windows,companion

Description:

View app windows from your own Mac on iPhone or iPad. App Stream discovers App Sync on your local network, securely pairs with your Mac, and lets you select an app window to stream. All Mac software runs on your Mac; App Stream does not sell or install remote software or provide cloud-hosted applications.

With App Sync from the Mac App Store, view windows already open on your Mac. Zoom, pan, and annotate locally while opening and arranging windows on the Mac. With the website edition of Vamp Sync, touch and keyboard control and window resizing are available after Accessibility permission is approved on the Mac. Settings explain the editions and provide product, support, and privacy links.

The App Store edition connects to your own Mac over trusted Wi-Fi/Ethernet or your private Tailscale network. A compatible App Sync or Vamp Sync host is required for Sync streaming. Vamp Assistant and Vamp Companion remain separate authenticated compatibility hosts. Connect both devices to the same tailnet when away from home. No Vamp account or hosted relay is required.

Review notes:

App Store connections, including saved connections and reconnects, support a physical Wi-Fi/Ethernet interface's directly connected subnet or private Tailscale device addresses. Tailscale destinations require an active tunnel carrying a tailnet address. MagicDNS names are resolved and the checked numeric address is used for the connection. Assistant and Companion HTTP requests are also checked, and redirects are refused. Existing pairing, host authentication, and permissions remain mandatory.

This build includes off-LAN Tailscale connections at the publisher's request. App Review guideline 4.2.7(a) currently specifies a local LAN for focused app-streaming clients; this feature may affect approval. Review notes must describe it accurately. TestFlight processing or internal distribution does not constitute App Store approval.

Pair with a Mac running App Sync on the same LAN. Verify fingerprints and approve the device on the Mac, then select an existing TextEdit window. The host reports Full Control or View Only, and Stream hides keyboard, remote app closing, and remote resizing in View Only mode. The comparison screen is available during onboarding and in Settings. For full input review, use the website Vamp Sync edition after independently granting its Accessibility permission. No account or in-app purchase is required.

## Before submitting

1. Validate signed archives and their actual entitlements in Xcode Organizer. The Sync store bundle must have App Sandbox, incoming/outgoing networking, and no Sparkle, Accessibility exception, or external updater. Stream does not request multicast entitlement; Bonjour discovery uses its declared service and Local Network consent.
2. Test signed Sync capture in the sandbox on a Mac with user-granted Screen Recording. Test Stream on a physical iPhone and iPad, using both Sync editions, denied permissions, rejected pairing, LAN/Tailscale reconnects, Tailscale disabled, MagicDNS, and rejected public addresses. A build or simulator check does not verify the signed sandbox capture flow.
3. Capture listing screenshots of real app use with sample content on your own Mac and devices. Avoid real fingerprints, addresses, names, or document contents. Upload the required iPhone/iPad and Mac screenshot sizes.
4. Publish the updated edition pages before submission. Add the actual App Store listing links after Apple assigns/releases them; the app uses stable product URLs and needs no binary update for a new listing URL.
5. Complete App Store Connect contact details, age rating, export compliance, and privacy disclosures. The current privacy manifests declare no developer-collected data, no tracking, and required reasons for local preferences/file timestamps. Confirm that against the final dependencies and actual practices; retain the distinction between private peer traffic and collection by the developer.

Apple's review remains a release step. Relevant requirements are [App Sandbox restrictions](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox) and [App Review Guidelines 2.4.5, 4.2.7, and 5.1.1](https://developer.apple.com/app-store/review/guidelines/).
