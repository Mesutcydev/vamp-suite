#!/usr/bin/env bash

# Build a device-only, unsigned Vamp Terminal IPA for AltStore to re-sign.
# This intentionally uses the active hand-maintained Xcode project; it must not
# regenerate or replace RemoteDesktopToolApps.xcodeproj with a stale copy.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/RemoteDesktopToolApps.xcodeproj"
SCHEME="VampTerminalApp"
WORK="$ROOT/.packaging-vamp-terminal-ios"
DERIVED_DATA="$WORK/DerivedData"
STAGING="$WORK/staging"
OUTPUT_DIR="$ROOT/dist/VampTerminal"
ALLOW_DIRTY=0
CLEAN=0

usage() {
  cat <<'EOF'
Usage: scripts/package-vamp-terminal-ios.sh [options]

Options:
  --output-dir <path>  Artifact destination (default: dist/VampTerminal)
  --clean              Remove the prior Vamp Terminal packaging workspace first
  --allow-dirty        Permit packaging from an uncommitted development tree
  --help               Show this help

The resulting IPA is intentionally unsigned. Import it into AltStore (or
another re-signing sideload tool), which signs it with the installing user's
Apple ID/team. This project does not ship certificates or provisioning profiles.
EOF
}

log() { printf '[vamp-terminal-ios] %s\n' "$*" >&2; }
fail() { printf '[vamp-terminal-ios] error: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      [[ $# -ge 2 ]] || fail "Missing value for --output-dir"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

# Packaging later changes into the staging directory. Resolve a caller-supplied
# relative destination now so the IPA is always written to the intended path.
if [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="$ROOT/$OUTPUT_DIR"
fi

for tool in xcodebuild ditto plutil file otool shasum python3 unzip zip; do
  command -v "$tool" >/dev/null 2>&1 || fail "Required tool not found: $tool"
done

[[ -d "$PROJECT" ]] || fail "Active Xcode project not found: $PROJECT"
[[ -e "$ROOT/.git" ]] || fail "Run this script from the Vamp project Git checkout"

COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
if [[ "$ALLOW_DIRTY" -ne 1 ]] && [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  fail "Release packaging requires a clean tree; use --allow-dirty for a local artifact"
fi

if [[ "$CLEAN" -eq 1 ]]; then
  [[ "$WORK" == "$ROOT/.packaging-vamp-terminal-ios" ]] || fail "Refusing to clean an unexpected path"
  log "Cleaning prior Vamp Terminal packaging output"
  rm -rf "$WORK"
  # Keep the artifact directory unambiguous when several builds were made
  # locally. Only this product's generated release files are removed.
  find "$OUTPUT_DIR" -maxdepth 1 -type f -name 'VampTerminal-iOS-*' -delete 2>/dev/null || true
fi

mkdir -p "$WORK" "$OUTPUT_DIR"

log "Building unsigned Release app for generic iOS device"
xcodebuild -quiet \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  build

APP="$DERIVED_DATA/Build/Products/Release-iphoneos/Vamp Terminal.app"
INFO="$APP/Info.plist"
EXECUTABLE="$APP/Vamp Terminal"
[[ -d "$APP" ]] || fail "Built app not found: $APP"
[[ -f "$INFO" ]] || fail "Built Info.plist not found"
[[ -x "$EXECUTABLE" ]] || fail "Built executable not found"

VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO")"
BUILD="$(plutil -extract CFBundleVersion raw "$INFO")"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$INFO")"
DISPLAY_NAME="$(plutil -extract CFBundleDisplayName raw "$INFO")"

[[ "$BUNDLE_ID" == "com.mesutcy.remotedesktop.terminal" ]] || fail "Unexpected bundle ID: $BUNDLE_ID"
[[ "$DISPLAY_NAME" == "Vamp Terminal" ]] || fail "Unexpected display name: $DISPLAY_NAME"
plutil -extract NSBonjourServices xml1 -o - "$INFO" | grep -q "_screenharbor._tcp" \
  || fail "Current _screenharbor._tcp Bonjour service is missing"
file "$EXECUTABLE" | grep -q "arm64" || fail "The device executable is not arm64"
[[ ! -e "$APP/embedded.mobileprovision" ]] || fail "Unsigned IPA unexpectedly contains a provisioning profile"
[[ ! -d "$APP/_CodeSignature" ]] || fail "Unsigned IPA unexpectedly contains a code signature"

ARTIFACT_NAME="VampTerminal-iOS-${VERSION}-build-${BUILD}-altstore-unsigned.ipa"
IPA="$OUTPUT_DIR/$ARTIFACT_NAME"
SHA_FILE="$IPA.sha256"
MANIFEST="$IPA.manifest.json"
SBOM="$IPA.sbom.cdx.json"

[[ "$STAGING" == "$WORK/staging" ]] || fail "Refusing to replace an unexpected staging path"
rm -rf "$STAGING"
mkdir -p "$STAGING/Payload"
ditto --norsrc --noextattr "$APP" "$STAGING/Payload/Vamp Terminal.app"
rm -f "$IPA"
(cd "$STAGING" && COPYFILE_DISABLE=1 zip -qryX "$IPA" Payload)

unzip -tq "$IPA" >/dev/null || fail "IPA ZIP integrity check failed"
(cd "$OUTPUT_DIR" && shasum -a 256 "$ARTIFACT_NAME" > "$(basename "$SHA_FILE")")
# Round-trip the checksum immediately so a truncated or corrupt write of the
# .sha256 file fails the release instead of being discovered at download time.
(cd "$OUTPUT_DIR" && shasum -a 256 -c "$(basename "$SHA_FILE")" >/dev/null) \
  || fail "SHA-256 round-trip verification failed for $ARTIFACT_NAME"
SHA256="$(awk '{print $1}' "$SHA_FILE")"
SIZE_BYTES="$(stat -f '%z' "$IPA")"
TREE_STATE="clean"
if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  TREE_STATE="dirty"
fi

ARTIFACT_NAME="$ARTIFACT_NAME" VERSION="$VERSION" BUILD="$BUILD" COMMIT="$COMMIT" \
  SHA256="$SHA256" SIZE_BYTES="$SIZE_BYTES" TREE_STATE="$TREE_STATE" MANIFEST="$MANIFEST" \
  python3 - <<'PY'
import datetime
import json
import os

payload = {
    "schemaVersion": 1,
    "artifact": os.environ["ARTIFACT_NAME"],
    "application": "Vamp Terminal",
    "platform": "iOS/iPadOS",
    "minimumOSVersion": "18.0",
    "version": os.environ["VERSION"],
    "build": os.environ["BUILD"],
    "bundleIdentifier": "com.mesutcy.remotedesktop.terminal",
    "architecture": ["arm64"],
    "signature": "unsigned",
    "requiresResigning": True,
    "sideloadTool": "AltStore",
    "sourceCommit": os.environ["COMMIT"],
    "sourceTreeState": os.environ["TREE_STATE"],
    "sha256": os.environ["SHA256"],
    "sizeBytes": int(os.environ["SIZE_BYTES"]),
    "createdAt": datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
}
with open(os.environ["MANIFEST"], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

# The release process promises a CycloneDX SBOM per artifact; skipping it
# silently when the generator is missing would ship that promise broken.
[[ -x "$ROOT/scripts/generate-vamp-sbom.sh" ]] \
  || fail "SBOM generator missing or not executable: scripts/generate-vamp-sbom.sh"
"$ROOT/scripts/generate-vamp-sbom.sh" \
    "$IPA" vamp-terminal "$VERSION" "$BUILD" "$COMMIT" "$SBOM"

log "Verified bundle: $BUNDLE_ID, iOS/iPadOS 18+, arm64, unsigned, AltStore-ready"
log "IPA: $IPA"
log "SHA-256: $SHA256"
