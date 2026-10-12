#!/usr/bin/env bash

# Build a device-only unsigned Vamp Control IPA for AltStore to re-sign.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/RemoteDesktopToolApps.xcodeproj"
WORK="$ROOT/.packaging-vamp-control-ios"
DERIVED_DATA="$WORK/DerivedData"
STAGING="$WORK/staging"
OUTPUT_DIR="$ROOT/dist/VampSuite"
CLEAN=0
ALLOW_DIRTY=0

log() { printf '[vamp-control-ios] %s\n' "$*" >&2; }
fail() { printf '[vamp-control-ios] error: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) [[ $# -ge 2 ]] || fail "Missing output directory"; OUTPUT_DIR="$2"; shift 2 ;;
    --clean) CLEAN=1; shift ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --help|-h) printf 'Usage: %s [--output-dir path] [--clean] [--allow-dirty]\n' "$0"; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

[[ "$OUTPUT_DIR" == /* ]] || OUTPUT_DIR="$ROOT/$OUTPUT_DIR"
for tool in xcodebuild ditto plutil file shasum python3 unzip zip; do
  command -v "$tool" >/dev/null 2>&1 || fail "Required tool not found: $tool"
done
[[ -d "$PROJECT" ]] || fail "Active Xcode project not found"
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
if [[ "$ALLOW_DIRTY" -ne 1 ]] && [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  fail "Release packaging requires a clean tree; use --allow-dirty for a local artifact"
fi
if [[ "$CLEAN" -eq 1 ]]; then
  [[ "$WORK" == "$ROOT/.packaging-vamp-control-ios" ]] || fail "Unexpected work path"
  rm -rf "$WORK"
  find "$OUTPUT_DIR" -maxdepth 1 -type f -name 'VampControl-iOS-*' -delete 2>/dev/null || true
fi
mkdir -p "$WORK" "$OUTPUT_DIR"

xcodebuild -quiet -project "$PROJECT" -scheme iOSRemote -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build

APP="$DERIVED_DATA/Build/Products/Release-iphoneos/Vamp Control iOS.app"
INFO="$APP/Info.plist"
[[ -d "$APP" ]] || fail "Built app not found: $APP"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO")"
BUILD="$(plutil -extract CFBundleVersion raw "$INFO")"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$INFO")"
DISPLAY_NAME="$(plutil -extract CFBundleDisplayName raw "$INFO")"
[[ "$BUNDLE_ID" == com.mesutcy.remotedesktop.ios ]] || fail "Unexpected bundle ID: $BUNDLE_ID"
[[ "$DISPLAY_NAME" == 'Vamp Control' ]] || fail "Unexpected display name: $DISPLAY_NAME"
file "$APP/Vamp Control iOS" | grep -q arm64 || fail "Executable is not arm64"
[[ ! -e "$APP/embedded.mobileprovision" ]] || fail "Unexpected provisioning profile"
[[ ! -d "$APP/_CodeSignature" ]] || fail "Unexpected code signature"

NAME="VampControl-iOS-${VERSION}-build-${BUILD}-altstore-unsigned.ipa"
IPA="$OUTPUT_DIR/$NAME"
rm -rf "$STAGING"
mkdir -p "$STAGING/Payload"
ditto --norsrc --noextattr "$APP" "$STAGING/Payload/Vamp Control iOS.app"
(cd "$STAGING" && COPYFILE_DISABLE=1 zip -qryX "$IPA" Payload)
unzip -tq "$IPA" >/dev/null
(cd "$OUTPUT_DIR" && shasum -a 256 "$NAME" > "$NAME.sha256")
SHA256="$(awk '{print $1}' "$IPA.sha256")"
SIZE_BYTES="$(stat -f '%z' "$IPA")"
TREE_STATE=clean; [[ -z "$(git -C "$ROOT" status --porcelain)" ]] || TREE_STATE=dirty
ARTIFACT="$NAME" VERSION="$VERSION" BUILD="$BUILD" COMMIT="$COMMIT" SHA256="$SHA256" \
  SIZE_BYTES="$SIZE_BYTES" TREE_STATE="$TREE_STATE" MANIFEST="$IPA.manifest.json" python3 - <<'PY'
import datetime, json, os
payload = {
  "schemaVersion": 1, "artifact": os.environ["ARTIFACT"], "application": "Vamp Control iOS",
  "installedDisplayName": "Vamp Control", "platform": "iOS/iPadOS", "minimumOSVersion": "18.0",
  "version": os.environ["VERSION"], "build": os.environ["BUILD"],
  "bundleIdentifier": "com.mesutcy.remotedesktop.ios", "architecture": ["arm64"],
  "signature": "unsigned", "requiresResigning": True, "sideloadTool": "AltStore",
  "sourceCommit": os.environ["COMMIT"], "sourceTreeState": os.environ["TREE_STATE"],
  "sha256": os.environ["SHA256"], "sizeBytes": int(os.environ["SIZE_BYTES"]),
  "createdAt": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
}
with open(os.environ["MANIFEST"], "w", encoding="utf-8") as f:
  json.dump(payload, f, indent=2); f.write("\n")
PY
"$ROOT/scripts/generate-vamp-sbom.sh" "$IPA" vamp-control-ios "$VERSION" "$BUILD" "$COMMIT" "$IPA.sbom.cdx.json"
log "Created $IPA"
log "SHA-256 $SHA256"
