# Vamp Control macOS — build 59 compliance update

Checked 23 October 2026. Existing ASC app **6778921377**, version **2.3.0**, bundle `com.mesutcy.remotedesktop.macclient`.

The privacy gaps and screenshot-fidelity issues identified in build 58 have been corrected. Build **59** is uploaded, processed **VALID / APP_STORE_ELIGIBLE**, and attached to the existing draft. The draft remains **PREPARE_FOR_SUBMISSION**, with manual release. It has not been submitted to App Review.

## Corrected

- **Accessible privacy and support:** Settings > Open Source and the Help menu expose direct Privacy Policy and Help links. The Help-menu privacy link was opened in Safari and resolved to the live policy. General preferences now distinguish the private key that stays on the Mac from the public identity and fingerprint shared during pairing. [Apple privacy guideline](https://developer.apple.com/app-store/review/guidelines/#privacy).
- **Required-reason declaration:** the actual signed archive includes `NSPrivacyAccessedAPICategorySystemBootTime`, with `35F9.1` for internal elapsed-time calculations and `8FFB.1` for local video timestamps. Existing User Defaults and File Timestamp reasons remain. Inspected uptime values remain in local timing/decode paths. [Apple API reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
- **Retention/deletion disclosure:** https://thevamp.app/privacy/ now documents persistent local records, trust revocation, removal of local files and compatibility Keychain items, exported files, support-report retention, and deletion requests. It explicitly distinguishes the in-app memory history from macOS-managed diagnostic logs. The published page was read back with HTTP 200 and both additions present.
- **Real screenshots:** the old component compositions were replaced by three actual app-window captures in each of English and Turkish: discovery, General preferences, and privacy/support. The complete captured windows keep the real chrome, tabs, content, and scroll state. Only uniform scaling, opaque background padding, and localized captions are added. All six ASC images are COMPLETE, 1440 × 900 RGB, correctly ordered, and match the local MD5 checksums. [Apple screenshot guidance](https://developer.apple.com/app-store/review/guidelines/#accurate-metadata).
- **App Privacy publication:** the ASC browser directly showed Published / Data Not Collected and the correct policy URL. No declaration change was necessary. The CLI's separate cached web session remains expired, but API authentication works and browser verification resolves the prior publication uncertainty.
- **Legacy purchase explanation:** review notes identify `com.vamp.desktop.unlimited` as a prior-version purchase and explain that this version includes its features for everyone. The live app's purchase availability was preserved; no promoted purchases are configured.

## Verification

- **42 MacClient tests passed**, zero failures, with the current Xcode toolchain.
- The original distribution archive and exported package passed signature, embedded profile/certificate, sandbox, user-selected-file, and identity verification. No external updater, sandbox exception, or debug entitlement is present.
- The local app used for capture has the **same machine-code text sections and non-signature resources** as the distribution archive. A separate runtime copy uses ad hoc signing with the same sandbox/network/file entitlements to permit local launch. The upload archive was not modified. `Screenshots/runtime-equivalence.json` records the comparison.
- ASC build: `f6b7cb84-6384-4c6b-868d-a09436b6714d`. Version: `1954ead0-7dfa-43ae-ae11-620bee6780cf`.
- Exact archive: `dist/AppStore/Control-2.3.0-build-59/Vamp Control-Store.xcarchive`.
- Package: `dist/AppStore/Control-2.3.0-build-59/VampControl-2.3.0-build-59-appstore.pkg`.
- Package SHA-256: `14110db983da1e664c16971469fe058eeda3065037e3544d936c8b153be72ed8`.
- Website changes were limited to the privacy page, preserving current published styling. Commits: `a39976e17193005251625a938ad5ec4d1427331b` and `975f2dbd463f2213df3dcf33bd2121fdd0f13f87`. Final product-scoped Pages run `39928531105` succeeded. The unscoped workflow has a separate missing-release-assets problem; no unrelated download code was changed.
- Release receipts, raw captures, image hashes, ASC readbacks, and the contact sheet are under `dist/AppStore/Control-2.3.0-build-59/`.

## Remaining review and runtime limits

An active streaming screenshot and a paired sandbox session test are still pending access to the installed Sync panel. The discovered Sync host reports an existing connection. The user authorized a brief disconnection, but the native controller times out while Sync's menu-bar popover is closed. No host restart, trust approval, permission change, TCC reset, or identity replacement was used. The current screenshots accurately show discovery and settings; they do not claim to show an active stream. Reconnect, host View Only enforcement, optional clipboard/file tools, and IPv6-only networking still need a real session check.

Off-LAN private Tailscale support remains honestly disclosed. Control provides a generic desktop view and optional focused app streaming; Apple's interpretation of the latter under 4.2.7 remains a review risk, not a verified rejection or an approval. [Apple remote-desktop guideline](https://developer.apple.com/app-store/review/guidelines/#minimum-functionality).

The image authoring script now accepts real window captures; it no longer renders SwiftUI fixture compositions for store upload. The historical Swift canvas is marked preview-only. Reproduce framing with `python3 scripts/render-vamp-control-store-screenshots.py --captures RAW_CAPTURE_DIR --archive ARCHIVE_PATH --output OUTPUT_DIR`.
