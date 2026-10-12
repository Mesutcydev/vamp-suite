#!/usr/bin/env bash
# Build a device-only, unsigned Vamp Stream IPA for AltStore-style re-signing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.packaging-vamp-stream-ios"
DERIVED="$WORK/DerivedData"
STAGING="$WORK/staging"
PROJECT="$ROOT/VampStream.xcodeproj"
OUTPUT="$ROOT/dist/VampStream"
CLEAN=0
ALLOW_DIRTY=0

fail() { printf '[vamp-stream-ios] error: %s\n' "$*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) [[ $# -ge 2 ]] || fail "Missing output path"; OUTPUT="$2"; shift 2 ;;
    --clean) CLEAN=1; shift ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --help|-h) printf 'Usage: scripts/package-vamp-stream-ios.sh [--output-dir path] [--clean] [--allow-dirty]\n'; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done
[[ "$OUTPUT" == /* ]] || OUTPUT="$ROOT/$OUTPUT"
for tool in xcodegen xcodebuild plutil file ditto zip unzip shasum; do command -v "$tool" >/dev/null || fail "Required tool not found: $tool"; done
[[ -f "$ROOT/vampstream-project.yml" ]] || fail "vampstream-project.yml is missing"
[[ -f "$ROOT/Configuration/VampStream.entitlements" ]] || fail "VampStream.entitlements is missing"
if [[ "$ALLOW_DIRTY" -ne 1 && -n "$(git -C "$ROOT" status --porcelain)" ]]; then fail "Use --allow-dirty for an uncommitted tree"; fi
if [[ "$CLEAN" -eq 1 ]]; then [[ "$WORK" == "$ROOT/.packaging-vamp-stream-ios" ]] || fail "Unexpected work path"; rm -rf "$WORK"; fi
mkdir -p "$WORK" "$OUTPUT"
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
xcodegen generate --spec "$ROOT/vampstream-project.yml"
xcodebuild -quiet -project "$PROJECT" -scheme VampStream -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build
APP="$DERIVED/Build/Products/Release-iphoneos/Vamp Stream.app"
[[ -d "$APP" ]] || fail "Built app not found: $APP"
INFO="$APP/Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO")"
BUILD="$(plutil -extract CFBundleVersion raw "$INFO")"
[[ "$(plutil -extract CFBundleIdentifier raw "$INFO")" == "com.mesutcy.remotedesktop.stream" ]] || fail "Unexpected bundle identifier"
file "$APP/Vamp Stream" | grep -q arm64 || fail "Device executable is not arm64"
[[ ! -e "$APP/embedded.mobileprovision" && ! -d "$APP/_CodeSignature" ]] || fail "IPA must remain unsigned"
NAME="VampStream-iOS-${VERSION}-build-${BUILD}-altstore-unsigned.ipa"
IPA="$OUTPUT/$NAME"
MANIFEST="$IPA.manifest.json"
SBOM="$IPA.sbom.cdx.json"
[[ "$STAGING" == "$WORK/staging" ]] || fail "Unexpected staging path"
rm -rf "$STAGING"; mkdir -p "$STAGING/Payload"; ditto --norsrc --noextattr "$APP" "$STAGING/Payload/Vamp Stream.app"
# zip updates existing archives in place, retaining removed app resources. Always
# create a fresh archive so repeated packaging cannot ship obsolete bundle files.
rm -f "$IPA"
(cd "$STAGING" && COPYFILE_DISABLE=1 zip -qryX "$IPA" Payload)
unzip -tq "$IPA" >/dev/null
(cd "$OUTPUT" && shasum -a 256 "$NAME" > "$NAME.sha256" && shasum -a 256 -c "$NAME.sha256" >/dev/null)
SHA256="$(awk '{print $1}' "$IPA.sha256")"
SIZE_BYTES="$(stat -f '%z' "$IPA")"
TREE_STATE=clean
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || TREE_STATE=dirty
ARTIFACT="$NAME" VERSION="$VERSION" BUILD="$BUILD" COMMIT="$COMMIT" SHA256="$SHA256" \
  SIZE_BYTES="$SIZE_BYTES" TREE_STATE="$TREE_STATE" MANIFEST="$MANIFEST" python3 - <<'PY'
import datetime
import json
import os

payload = {
    "schemaVersion": 1,
    "artifact": os.environ["ARTIFACT"],
    "application": "Vamp Stream",
    "platform": "iOS/iPadOS",
    "minimumOSVersion": "18.0",
    "version": os.environ["VERSION"],
    "build": os.environ["BUILD"],
    "bundleIdentifier": "com.mesutcy.remotedesktop.stream",
    "architecture": ["arm64"],
    "signature": "unsigned",
    "requiresResigning": True,
    "sideloadTool": "AltStore",
    "sourceCommit": os.environ["COMMIT"],
    "sourceTreeState": os.environ["TREE_STATE"],
    "sha256": os.environ["SHA256"],
    "sizeBytes": int(os.environ["SIZE_BYTES"]),
    "createdAt": datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0).isoformat().replace("+00:00", "Z"),
}
with open(os.environ["MANIFEST"], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY
[[ -x "$ROOT/scripts/generate-vamp-sbom.sh" ]] || fail "SBOM generator is missing"
"$ROOT/scripts/generate-vamp-sbom.sh" \
  "$IPA" vamp-stream-ios "$VERSION" "$BUILD" "$COMMIT" "$SBOM"
python3 "$ROOT/scripts/verify-vamp-stream-ipa.py" "$IPA"
printf '[vamp-stream-ios] wrote %s\n' "$IPA"
