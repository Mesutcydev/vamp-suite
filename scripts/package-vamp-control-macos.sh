#!/usr/bin/env bash

# Build the direct-distribution Vamp Control macOS client.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/MacClient.xcodeproj"
WORK="$ROOT/.packaging-vamp-control-macos"
OUTPUT_DIR="$ROOT/dist/VampSuite"
CLEAN=0
ALLOW_DIRTY=0
log() { printf '[vamp-control-macos] %s\n' "$*" >&2; }
fail() { printf '[vamp-control-macos] error: %s\n' "$*" >&2; exit 1; }
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
for tool in xcodebuild xcodegen codesign ditto hdiutil plutil file shasum python3; do command -v "$tool" >/dev/null || fail "Missing $tool"; done
[[ -f "$ROOT/macclient-project.yml" ]] || fail "Missing macclient-project.yml"
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
if [[ "$ALLOW_DIRTY" -ne 1 ]] && [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then fail "Use --allow-dirty for local artifacts"; fi
if [[ "$CLEAN" -eq 1 ]]; then
  [[ "$WORK" == "$ROOT/.packaging-vamp-control-macos" ]] || fail "Unexpected work path"
  rm -rf "$WORK"
  find "$OUTPUT_DIR" -maxdepth 1 -type f -name 'VampControl-macOS-*' -delete 2>/dev/null || true
fi
mkdir -p "$WORK" "$OUTPUT_DIR"
(cd "$ROOT" && xcodegen generate --spec macclient-project.yml >/dev/null)
xcodebuild -quiet -project "$PROJECT" -scheme MacClient -configuration Release -sdk macosx \
  -destination 'generic/platform=macOS' -derivedDataPath "$WORK/DerivedData" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= ENABLE_DEBUG_DYLIB=NO build
APP="$WORK/DerivedData/Build/Products/Release/Vamp Control macOS.app"
INFO="$APP/Contents/Info.plist"
[[ -d "$APP" ]] || fail "Built app not found"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO")"; BUILD="$(plutil -extract CFBundleVersion raw "$INFO")"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$INFO")"; DISPLAY="$(plutil -extract CFBundleDisplayName raw "$INFO")"
[[ "$BUNDLE_ID" == com.mesutcy.remotedesktop.macclient ]] || fail "Unexpected bundle ID: $BUNDLE_ID"
[[ "$DISPLAY" == 'Vamp Control' ]] || fail "Unexpected display name: $DISPLAY"
file "$APP/Contents/MacOS/Vamp Control macOS" | grep -q arm64 || fail "Executable is not arm64"
# The direct-distribution client must not ship Sparkle: macOS rejects the bundled
# framework signature in an ad-hoc distributed app (dyld aborts at launch).
if otool -L "$APP/Contents/MacOS/Vamp Control macOS" | grep -qi "Sparkle"; then
  fail "Sparkle must not be linked into the Vamp Control macOS client"
fi
if find "$APP" -iname '*Sparkle*' -print -quit | grep -q .; then
  fail "Sparkle files must not be embedded in the Vamp Control macOS client"
fi
# Sign the whole bundle inside-out with a single ad-hoc identity. Signing every
# nested framework/xpc/app with the same (empty) Team ID as the app keeps macOS
# library validation happy at launch: a bundled framework signed by a different
# team is rejected by dyld ("mapping process and mapped file have different Team
# IDs"), which previously crashed the app on start when Sparkle was embedded.
# Sparkle has since been removed, but a deep ad-hoc sign remains the correct,
# future-proof way to seal any nested code the app may carry.
codesign --force --deep --sign - --options runtime "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
NAME="VampControl-macOS-${VERSION}-build-${BUILD}-adhoc.zip"; ZIP="$OUTPUT_DIR/$NAME"
rm -f "$ZIP"; ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"; SIZE="$(stat -f '%z' "$ZIP")"
printf '%s  %s\n' "$SHA256" "$NAME" > "$ZIP.sha256"
TREE_STATE=clean; [[ -z "$(git -C "$ROOT" status --porcelain)" ]] || TREE_STATE=dirty
ARTIFACT="$NAME" VERSION="$VERSION" BUILD="$BUILD" COMMIT="$COMMIT" SHA256="$SHA256" SIZE="$SIZE" \
 TREE_STATE="$TREE_STATE" MANIFEST="$ZIP.manifest.json" python3 - <<'PY'
import datetime, json, os
payload={"schemaVersion":1,"artifact":os.environ["ARTIFACT"],"application":"Vamp Control macOS",
"installedDisplayName":"Vamp Control","platform":"macOS","minimumOSVersion":"13.0",
"version":os.environ["VERSION"],"build":os.environ["BUILD"],"bundleIdentifier":"com.mesutcy.remotedesktop.macclient",
"architecture":["arm64"],"signature":"ad-hoc","appleNotarized":False,
"sourceCommit":os.environ["COMMIT"],"sourceTreeState":os.environ["TREE_STATE"],"sha256":os.environ["SHA256"],
"sizeBytes":int(os.environ["SIZE"]),"createdAt":datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00","Z")}
with open(os.environ["MANIFEST"],"w",encoding="utf-8") as f: json.dump(payload,f,indent=2); f.write("\n")
PY
"$ROOT/scripts/generate-vamp-sbom.sh" "$ZIP" vamp-control-macos "$VERSION" "$BUILD" "$COMMIT" "$ZIP.sbom.cdx.json"

# Also ship the normal macOS drag-to-Applications disk image. Keep the ZIP for
# users and automation that already consume it, but make the DMG the primary
# human installation artifact.
DMG_STAGE="$WORK/dmg-root"
[[ "$DMG_STAGE" == "$ROOT/.packaging-vamp-control-macos/dmg-root" ]] || fail "Unexpected DMG staging path"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
ditto "$APP" "$DMG_STAGE/Vamp Control macOS.app"
ln -s /Applications "$DMG_STAGE/Applications"
DMG_NAME="VampControl-macOS-${VERSION}-build-${BUILD}-adhoc.dmg"
DMG="$OUTPUT_DIR/$DMG_NAME"
rm -f "$DMG"
hdiutil create -quiet -ov -fs HFS+ -volname "Vamp Control" -srcfolder "$DMG_STAGE" "$DMG"
DMG_SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
DMG_SIZE="$(stat -f '%z' "$DMG")"
printf '%s  %s\n' "$DMG_SHA256" "$DMG_NAME" > "$DMG.sha256"
ARTIFACT="$DMG_NAME" VERSION="$VERSION" BUILD="$BUILD" COMMIT="$COMMIT" SHA256="$DMG_SHA256" SIZE="$DMG_SIZE" \
 TREE_STATE="$TREE_STATE" MANIFEST="$DMG.manifest.json" python3 - <<'PY'
import datetime, json, os
payload={"schemaVersion":1,"artifact":os.environ["ARTIFACT"],"application":"Vamp Control macOS",
"installedDisplayName":"Vamp Control","platform":"macOS","minimumOSVersion":"13.0",
"version":os.environ["VERSION"],"build":os.environ["BUILD"],"bundleIdentifier":"com.mesutcy.remotedesktop.macclient",
"architecture":["arm64"],"signature":"ad-hoc","appleNotarized":False,
"sourceCommit":os.environ["COMMIT"],"sourceTreeState":os.environ["TREE_STATE"],"sha256":os.environ["SHA256"],
"sizeBytes":int(os.environ["SIZE"]),"createdAt":datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00","Z")}
with open(os.environ["MANIFEST"],"w",encoding="utf-8") as f: json.dump(payload,f,indent=2); f.write("\n")
PY
"$ROOT/scripts/generate-vamp-sbom.sh" "$DMG" vamp-control-macos "$VERSION" "$BUILD" "$COMMIT" "$DMG.sbom.cdx.json"
log "Created $ZIP"
log "Created $DMG"
