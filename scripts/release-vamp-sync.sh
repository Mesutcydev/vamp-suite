#!/usr/bin/env bash
# Build an archive for Xcode notarization, then package the exported notarized app.
# Alternatively notarize a signed archive with a notarytool Keychain profile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.packaging-vamp-hosts"
OUTPUT="$ROOT/dist/VampStreamHost"
IDENTITY="${VAMP_SYNC_SIGN_IDENTITY:-}"
TEAM="${VAMP_SYNC_TEAM_ID:-}"
PROFILE="${VAMP_SYNC_NOTARY_PROFILE:-}"
ARCHS="${VAMP_HOST_ARCHS:-arm64 x86_64}"
ACCOUNT="${VAMP_SYNC_SPARKLE_ACCOUNT:-vamp-sync}"
EXPORTED_APP=""
DOWNLOAD_PREFIX=""
ALLOW_DIRTY=0
ARCHIVE_ONLY=0

usage() {
  cat <<'EOF'
Usage: scripts/release-vamp-sync.sh [options]

  --identity <SHA-1 or name>  Developer ID Application identity (or VAMP_SYNC_SIGN_IDENTITY)
  --team <team-id>           Developer team for archiving (or VAMP_SYNC_TEAM_ID)
  --archive-only             Build an archive for Xcode Organizer (default without a profile)
  --exported-app <path>      Package the notarized app exported from Xcode
  --notary-profile <name>    Keychain profile for notarization, including the outer DMG
  --download-prefix <HTTPS>  Published archive URL prefix (defaults to a versioned GitHub release)
  --output-dir <path>        Artifact directory (default: dist/VampStreamHost)
  --archs <value>            Xcode ARCHS (default: "arm64 x86_64")
  --allow-dirty             Permit a local release from uncommitted sources
  --help                    Show help

Xcode flow:
  1. Run --archive-only with your identity and team.
  2. Open the archive in Xcode. Distribute App → Direct Distribution → Distribute.
  3. After Apple accepts it, export the app and run --exported-app <path>.

The private Sparkle key remains in Keychain (account "vamp-sync").
This script never installs the app, commits sources, or publishes a release.
EOF
}
log() { printf '[vamp-sync-release] %s\n' "$*" >&2; }
fail() { log "error: $*"; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity|--team|--exported-app|--notary-profile|--download-prefix|--output-dir|--archs)
      [[ $# -ge 2 && -n "$2" ]] || fail "Missing value for $1"
      case "$1" in
        --identity) IDENTITY="$2" ;;
        --team) TEAM="$2" ;;
        --exported-app) EXPORTED_APP="$2" ;;
        --notary-profile) PROFILE="$2" ;;
        --download-prefix) DOWNLOAD_PREFIX="$2" ;;
        --output-dir) OUTPUT="$2" ;;
        --archs) ARCHS="$2" ;;
      esac
      shift 2 ;;
    --archive-only) ARCHIVE_ONLY=1; shift ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

for tool in xcodegen xcodebuild codesign xcrun ditto hdiutil plutil shasum python3 security; do
  command -v "$tool" >/dev/null || fail "Required tool not found: $tool"
done
[[ -n "$IDENTITY" && "$IDENTITY" != '-' ]] || fail "Specify a Developer ID Application --identity"
[[ "$OUTPUT" == /* ]] || OUTPUT="$ROOT/$OUTPUT"
[[ -z "$EXPORTED_APP" || "$ARCHIVE_ONLY" -eq 0 ]] || fail "--archive-only and --exported-app are mutually exclusive"
if [[ "$ALLOW_DIRTY" -ne 1 && -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]]; then
  fail "Release requires a clean tree; use --allow-dirty for a local artifact"
fi
mkdir -p "$WORK" "$OUTPUT"
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
TREE_STATE=clean
[[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]] || TREE_STATE=dirty
ARCHIVE="$WORK/Vamp Sync.xcarchive"

if [[ -z "$EXPORTED_APP" ]]; then
  log "Building universal Developer ID archive"
  xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"
  xcodebuild -quiet -project "$ROOT/RemoteDesktopToolApps.xcodeproj" -scheme VampMiniHost \
    -configuration Release -sdk macosx -destination 'generic/platform=macOS' \
    -derivedDataPath "$ROOT/.derived-vampsync-sparkle" -archivePath "$ARCHIVE" \
    ARCHS="$ARCHS" ONLY_ACTIVE_ARCH=NO CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
    ENABLE_HARDENED_RUNTIME=YES ENABLE_DEBUG_DYLIB=NO archive
  if [[ "$ARCHIVE_ONLY" -eq 1 || -z "$PROFILE" ]]; then
    log "Archive ready: $ARCHIVE"
    log "Open in Xcode; choose Distribute App → Direct Distribution. Export after notarization."
    exit 0
  fi
  # Xcode signs nested Sparkle helpers during archive export. A build's
  # Code Sign on Copy alone does not sign those helpers for distribution.
  [[ -n "$TEAM" ]] || fail "--team is required for Developer ID export"
  EXPORT_PLIST="$WORK/ExportOptions.plist"
  python3 - "$EXPORT_PLIST" "$TEAM" "$IDENTITY" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump({'method':'developer-id', 'teamID':sys.argv[2],
                  'signingStyle':'manual', 'signingCertificate':sys.argv[3]}, f)
PY
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$WORK/export" \
    -exportOptionsPlist "$EXPORT_PLIST"
  EXPORTED_APP="$WORK/export/Vamp Sync.app"
  ditto -c -k --sequesterRsrc --keepParent "$EXPORTED_APP" "$WORK/notarization.zip"
  xcrun notarytool submit "$WORK/notarization.zip" --keychain-profile "$PROFILE" \
    --wait --output-format json > "$WORK/notarization-result.json"
  python3 - "$WORK/notarization-result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit(f"Notarization was not accepted: {result}. Retrieve the notarytool log before retrying.")
PY
  xcrun stapler staple "$EXPORTED_APP"
fi

[[ -d "$EXPORTED_APP" ]] || fail "Exported app not found: $EXPORTED_APP"
INFO="$EXPORTED_APP/Contents/Info.plist"
[[ "$(plutil -extract CFBundleIdentifier raw "$INFO")" == com.mesutcy.remotedesktop.minhost ]] \
  || fail "The exported app is not Vamp Sync"
codesign --verify --deep --strict "$EXPORTED_APP"
SIGNING_DETAILS="$(codesign -d --verbose=4 "$EXPORTED_APP" 2>&1)"
[[ "$SIGNING_DETAILS" == *'Authority=Developer ID Application:'* ]] || fail "App must be Developer ID signed"
[[ "$SIGNING_DETAILS" == *'flags='*'(runtime)'* ]] || fail "App must enable Hardened Runtime"
xcrun stapler validate "$EXPORTED_APP"
spctl --assess --type execute --verbose=2 "$EXPORTED_APP"

VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO")"
BUILD="$(plutil -extract CFBundleVersion raw "$INFO")"
STEM="VampSync-macOS-${VERSION}-build-${BUILD}"
ZIP="$OUTPUT/${STEM}-notarized.zip"
DMG="$OUTPUT/${STEM}-notarized.dmg"
[[ -n "$DOWNLOAD_PREFIX" ]] || DOWNLOAD_PREFIX="https://github.com/Mesutcydev/vamp-suite/releases/download/vamp-sync-${VERSION}-build-${BUILD}/"
[[ "$DOWNLOAD_PREFIX" == https://* ]] || fail "Sparkle downloads must use HTTPS"
SPARKLE_BIN="${VAMP_SYNC_SPARKLE_BIN:-$ROOT/.derived-vampsync-sparkle/SourcePackages/artifacts/sparkle/Sparkle/bin}"
[[ -x "$SPARKLE_BIN/generate_keys" && -x "$SPARKLE_BIN/generate_appcast" && -x "$SPARKLE_BIN/sign_update" ]] \
  || fail "Sparkle tools not found; set VAMP_SYNC_SPARKLE_BIN to the Sparkle bin directory"
PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" --account "$ACCOUNT" -p)"
[[ "$PUBLIC_KEY" == "$(plutil -extract SUPublicEDKey raw "$INFO")" ]] \
  || fail "Sparkle Keychain public key does not match the exported app"
[[ "$(plutil -extract SUFeedURL raw "$INFO")" == https://thevamp.app/sync/appcast.xml ]] \
  || fail "Unexpected Vamp Sync update feed"

# Keep the app's stapled ticket and bundle signature intact.
ditto -c -k --sequesterRsrc --keepParent "$EXPORTED_APP" "$ZIP"
STAGE="$(mktemp -d "$WORK/dmg-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$EXPORTED_APP" "$STAGE/Vamp Sync.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname 'Vamp Sync' -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
DMG_NOTARIZED=false
if [[ -n "$PROFILE" ]]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait \
    --output-format json > "$WORK/dmg-notarization-result.json"
  python3 - "$WORK/dmg-notarization-result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit(f"Disk image notarization was not accepted: {result}")
PY
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  DMG_NOTARIZED=true
fi

for artifact in "$ZIP" "$DMG"; do
  checksum="$(shasum -a 256 "$artifact" | awk '{print $1}')"
  printf '%s  %s\n' "$checksum" "$(basename "$artifact")" > "$artifact.sha256"
  (cd "$OUTPUT" && shasum -a 256 -c "$(basename "$artifact").sha256")
  python3 - "$artifact" "$INFO" "$COMMIT" "$TREE_STATE" "$checksum" "$DMG_NOTARIZED" <<'PY'
import datetime, json, pathlib, plistlib, subprocess, sys
artifact, info_path, commit, tree, checksum, dmg_notarized = sys.argv[1:]
info = plistlib.load(open(info_path, 'rb'))
details = subprocess.run(['codesign','-d','--verbose=4',str(pathlib.Path(info_path).parents[1])],capture_output=True,text=True,check=True).stderr
team = next(line.split('=',1)[1] for line in details.splitlines() if line.startswith('TeamIdentifier='))
archs = subprocess.check_output(['lipo','-archs',str(pathlib.Path(info_path).parent/'MacOS'/info['CFBundleExecutable'])],text=True).split()
payload = {'schemaVersion':1, 'artifact':pathlib.Path(artifact).name,
           'application':'Vamp Sync', 'platform':'macOS', 'minimumOSVersion':info['LSMinimumSystemVersion'],
           'version':info['CFBundleShortVersionString'], 'build':info['CFBundleVersion'],
           'bundleIdentifier':info['CFBundleIdentifier'], 'architecture':archs,
           'signature':'Developer ID', 'teamIdentifier':team, 'appleNotarized':True,
           'diskImageNotarized':dmg_notarized == 'true' if artifact.endswith('.dmg') else None,
           'containerSignature':('Developer ID' if dmg_notarized == 'true' else 'unsigned') if artifact.endswith('.dmg') else None,
           'sourceRepository':'https://github.com/Mesutcydev/vamp-suite', 'sourceCommit':commit,
           'sourceTreeState':tree, 'sha256':checksum, 'sizeBytes':pathlib.Path(artifact).stat().st_size,
           'createdAt':datetime.datetime.now(datetime.timezone.utc).isoformat()}
pathlib.Path(artifact+'.manifest.json').write_text(json.dumps(payload,indent=2)+'\n')
PY
  VAMP_ARTIFACT_SIGNATURE='Developer ID' VAMP_ARTIFACT_NOTARIZED=true \
    "$ROOT/scripts/generate-vamp-sbom.sh" \
    "$artifact" vamp-mini-host "$VERSION" "$BUILD" "$COMMIT" "$artifact.sbom.cdx.json"
done

# The appcast is generated from the final archive, after all ticket changes.
# It stays in dist until the matching release asset and feed are published.
FEED_DIR="$OUTPUT/sparkle"
mkdir -p "$FEED_DIR"
UPDATE_ARCHIVE="$ZIP"
[[ "$DMG_NOTARIZED" == true ]] && UPDATE_ARCHIVE="$DMG"
cp "$UPDATE_ARCHIVE" "$FEED_DIR/"
"$SPARKLE_BIN/generate_appcast" --account "$ACCOUNT" --maximum-deltas 0 \
  --download-url-prefix "${DOWNLOAD_PREFIX%/}/" --link https://thevamp.app/sync/ \
  -o "$FEED_DIR/appcast.xml" "$FEED_DIR"
"$SPARKLE_BIN/sign_update" --account "$ACCOUNT" "$FEED_DIR/appcast.xml"
"$SPARKLE_BIN/sign_update" --account "$ACCOUNT" --verify "$FEED_DIR/appcast.xml"
python3 - "$FEED_DIR/appcast.xml" "$UPDATE_ARCHIVE" "$BUILD" "$DOWNLOAD_PREFIX" "$SPARKLE_BIN/sign_update" "$ACCOUNT" <<'PY'
import pathlib, subprocess, sys, xml.etree.ElementTree as ET
feed, archive, build, prefix, signer, account = sys.argv[1:]
ns = {'sparkle':'http://www.andymatuschak.org/xml-namespaces/sparkle'}
items = [item for item in ET.parse(feed).findall('./channel/item') if item.findtext('sparkle:version',namespaces=ns) == build]
if len(items) != 1:
    raise SystemExit('Appcast must contain exactly one entry for this build')
enclosure = items[0].find('enclosure')
assert enclosure.attrib['url'] == prefix.rstrip('/')+'/'+pathlib.Path(archive).name
assert int(enclosure.attrib['length']) == pathlib.Path(archive).stat().st_size
signature = enclosure.attrib['{'+ns['sparkle']+'}edSignature']
subprocess.run([signer,'--account',account,'--verify',archive,signature],check=True)
PY
log "Notarized app packaged: $ZIP and $DMG"
log "Signed update feed ready: $FEED_DIR/appcast.xml"
if [[ "$DMG_NOTARIZED" == false ]]; then
  log "The app has Apple's stapled ticket. The outer DMG is unsigned; Sparkle uses the EdDSA-signed ZIP."
fi
log "Publish the matching GitHub release assets, then copy appcast.xml to docs/sync/appcast.xml."
