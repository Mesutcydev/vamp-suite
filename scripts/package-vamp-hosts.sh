#!/usr/bin/env bash

# Build Vamp Sync, the only maintained macOS host in this repository.
# The apps are ad-hoc signed with Apple's local '-' identity, never notarized,
# and are intended for user-controlled open-source testing and distribution.
# Use release-vamp-sync.sh for Developer ID signing and Apple notarization.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/RemoteDesktopToolApps.xcodeproj"
WORK="$ROOT/.packaging-vamp-hosts"
OUTPUT_DIR="$ROOT/dist/VampStreamHost"
ARCHS="${VAMP_HOST_ARCHS:-arm64}"
CLEAN=0
ALLOW_DIRTY=0
ONLY_SCHEME="VampMiniHost"

usage() {
  cat <<'EOF'
Usage: scripts/package-vamp-hosts.sh [options]

Options:
  --output-dir <path>  Artifact destination (default: dist/VampStreamHost)
  --archs <value>      Xcode ARCHS value (default: arm64; use "arm64 x86_64" for universal)
  --clean              Remove the prior host packaging workspace first
  --allow-dirty        Permit packaging from an uncommitted development tree
  --only <scheme>      VampMiniHost only (stable Sync scheme name)
  --help               Show this help

The resulting ZIP and DMG contain Vamp Sync.
Vamp Host and Vamp Terminal Host are discontinued and are not packaged.
They are ad-hoc signed, not notarized, and may require the user to approve them
in macOS Privacy & Security.
EOF
}

log() { printf '[vamp-hosts] %s\n' "$*" >&2; }
fail() { printf '[vamp-hosts] error: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      [[ $# -ge 2 ]] || fail "Missing value for --output-dir"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --archs)
      [[ $# -ge 2 ]] || fail "Missing value for --archs"
      ARCHS="$2"
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
    --only)
      [[ $# -ge 2 ]] || fail "Missing value for --only"
      ONLY_SCHEME="$2"
      case "$ONLY_SCHEME" in VampMiniHost) ;; *) fail "Discontinued or unsupported host: $ONLY_SCHEME. Use Vamp Sync (VampMiniHost)." ;; esac
      shift 2
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

if [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="$ROOT/$OUTPUT_DIR"
fi

for tool in xcodebuild codesign ditto hdiutil plutil file otool shasum python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "Required tool not found: $tool"
done

[[ -d "$PROJECT" ]] || fail "Active Xcode project not found: $PROJECT"
# `.git` is a directory in a normal checkout and a file in a git worktree; accept
# both so packaging works from a worktree (all git commands below use `git -C`).
[[ -e "$ROOT/.git" ]] || fail "Run this script from the Vamp project Git checkout"

COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
if [[ "$ALLOW_DIRTY" -ne 1 ]] && [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]]; then
  fail "Release packaging requires a clean tree; use --allow-dirty for a local artifact"
fi

if [[ "$CLEAN" -eq 1 ]]; then
  [[ "$WORK" == "$ROOT/.packaging-vamp-hosts" ]] || fail "Refusing to clean an unexpected path"
  log "Cleaning prior Vamp Host packaging workspace"
  rm -rf "$WORK"
  # Remove only generated Vamp host files so stale downloads cannot be
  # mistaken for the build just produced.
  find "$OUTPUT_DIR" -maxdepth 1 -type f \( -name 'VampHost-macOS-*' -o -name 'VampTerminalHost-macOS-*' -o -name 'VampMiniHost-macOS-*' -o -name 'VampSync-macOS-*' \) -delete 2>/dev/null || true
fi

mkdir -p "$WORK" "$OUTPUT_DIR"

package_host() {
  local scheme="$1"
  local app_name="$2"
  local expected_bundle_id="$3"
  local stem="$4"
  local host_work="$WORK/$scheme"
  local derived_data="$host_work/DerivedData"
  local app="$derived_data/Build/Products/Release/$app_name.app"

  mkdir -p "$host_work"
  log "Building $app_name ($ARCHS, ad-hoc direct distribution)"
  xcodebuild -quiet \
    -project "$PROJECT" \
    -scheme "$scheme" \
    -configuration Release \
    -sdk macosx \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$derived_data" \
    ARCHS="$ARCHS" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    DEVELOPMENT_TEAM= \
    ENABLE_DEBUG_DYLIB=NO \
    build

  [[ -d "$app" ]] || fail "Built app not found: $app"
  local info="$app/Contents/Info.plist"
  local executable="$app/Contents/MacOS/$app_name"
  [[ -f "$info" ]] || fail "Built Info.plist not found: $info"
  [[ -x "$executable" ]] || fail "Built executable not found: $executable"

  # Direct-distribution applications must never retain Xcode's debug-dylib
  # indirection. Besides being unnecessary in Release, independently signing
  # that dylib can give it a different Team ID and make dyld abort at launch.
  if otool -L "$executable" | grep -q "${app_name}.debug.dylib"; then
    fail "$app_name executable unexpectedly depends on a debug dylib"
  fi

  local bundle_id version build display_name
  bundle_id="$(plutil -extract CFBundleIdentifier raw "$info")"
  version="$(plutil -extract CFBundleShortVersionString raw "$info")"
  build="$(plutil -extract CFBundleVersion raw "$info")"
  display_name="$(plutil -extract CFBundleName raw "$info")"
  [[ "$bundle_id" == "$expected_bundle_id" ]] || fail "Unexpected bundle ID for $app_name: $bundle_id"
  [[ "$display_name" == "$app_name" ]] || fail "Unexpected display name for $app_name: $display_name"
  plutil -extract NSBonjourServices xml1 -o - "$info" | grep -q "_screenharbor._tcp" \
    || fail "$app_name is missing the _screenharbor._tcp discovery contract"
  file "$executable" | grep -q "arm64" || fail "$app_name is not an arm64 build"

  # Include the source-facing notices in the app bundle so a standalone ZIP
  # remains useful when it is copied away from the repository.
  mkdir -p "$app/Contents/Resources"
  cp "$ROOT/LICENSE" "$app/Contents/Resources/LICENSE"
  cp "$ROOT/NOTICE" "$app/Contents/Resources/NOTICE"
  cp "$ROOT/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"

  # A bare ad-hoc signature keeps direct-distribution hosts unsandboxed. The
  # full host needs input injection and Terminal Mode; the light host only
  # needs its loopback/Tailscale terminal surface.
  codesign --force --sign - --options runtime "$app" >/dev/null
  codesign --verify --deep --strict "$app" >/dev/null

  local artifact="$OUTPUT_DIR/${stem}-macOS-${version}-build-${build}-adhoc.zip"
  local sha_file="$artifact.sha256"
  local manifest="$artifact.manifest.json"
  local sbom="$artifact.sbom.cdx.json"
  rm -f "$artifact" "$sha_file" "$manifest" "$sbom"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$artifact"
  local sha256 size tree_state
  sha256="$(shasum -a 256 "$artifact" | awk '{print $1}')"
  size="$(stat -f '%z' "$artifact")"
  printf '%s  %s\n' "$sha256" "$(basename "$artifact")" > "$sha_file"
  # Round-trip the checksum immediately so a corrupt .sha256 write fails the
  # release instead of being discovered at download time.
  (cd "$OUTPUT_DIR" && shasum -a 256 -c "$(basename "$sha_file")" >/dev/null) \
    || fail "SHA-256 round-trip verification failed for $(basename "$artifact")"
  tree_state="clean"
  [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]] || tree_state="dirty"

  local manifest_app_name="$app_name"
  [[ "$scheme" == "VampMiniHost" ]] && manifest_app_name="Vamp Sync"
  ARTIFACT="$(basename "$artifact")" APP_NAME="$manifest_app_name" BUNDLE_ID="$bundle_id" \
    VERSION="$version" BUILD="$build" ARCHS="$ARCHS" SHA256="$sha256" SIZE="$size" \
    COMMIT="$COMMIT" TREE_STATE="$tree_state" MANIFEST="$manifest" \
    python3 - <<'PY'
import datetime
import json
import os

payload = {
    "schemaVersion": 1,
    "artifact": os.environ["ARTIFACT"],
    "application": os.environ["APP_NAME"],
    "platform": "macOS",
    "minimumOSVersion": "13.0",
    "version": os.environ["VERSION"],
    "build": os.environ["BUILD"],
    "bundleIdentifier": os.environ["BUNDLE_ID"],
    "architecture": os.environ["ARCHS"].split(),
    "signature": "ad-hoc",
    "appleNotarized": False,
    "sourceRepository": "https://github.com/Mesutcydev/vamp-suite",
    "sourceCommit": os.environ["COMMIT"],
    "sourceTreeState": os.environ["TREE_STATE"],
    "sha256": os.environ["SHA256"],
    "sizeBytes": int(os.environ["SIZE"]),
    "createdAt": datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
}
with open(os.environ["MANIFEST"], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

  local package_kind
  case "$scheme" in
    MacHost) package_kind="vamp-host" ;;
    VampTerminalHost) package_kind="vamp-terminal-host" ;;
    VampMiniHost) package_kind="vamp-mini-host" ;;
    *) fail "Unknown host scheme: $scheme" ;;
  esac
  "$ROOT/scripts/generate-vamp-sbom.sh" \
    "$artifact" "$package_kind" "$version" "$build" "$COMMIT" "$sbom"

  log "Created $(basename "$artifact")"
  log "SHA-256 $sha256"

  if [[ "$scheme" == "VampMiniHost" ]]; then
    # Publish a real DMG as well as the ZIP. The website advertises the DMG as
    # the menu-bar install artifact, while the ZIP remains useful for source
    # and automation workflows.
    local dmg_stage="$host_work/dmg"
    local dmg_artifact="$OUTPUT_DIR/${stem}-macOS-${version}-build-${build}-adhoc.dmg"
    local dmg_sha_file="$dmg_artifact.sha256"
    local dmg_manifest="$dmg_artifact.manifest.json"
    local dmg_sbom="$dmg_artifact.sbom.cdx.json"
    rm -rf "$dmg_stage"
    mkdir -p "$dmg_stage"
    ditto --norsrc --noextattr "$app" "$dmg_stage/$app_name.app"
    rm -f "$dmg_artifact" "$dmg_sha_file" "$dmg_manifest" "$dmg_sbom"
    hdiutil create \
      -volname "Vamp Sync" \
      -srcfolder "$dmg_stage" \
      -ov \
      -format UDZO \
      "$dmg_artifact" >/dev/null

    local dmg_sha256 dmg_size
    dmg_sha256="$(shasum -a 256 "$dmg_artifact" | awk '{print $1}')"
    dmg_size="$(stat -f '%z' "$dmg_artifact")"
    printf '%s  %s\n' "$dmg_sha256" "$(basename "$dmg_artifact")" > "$dmg_sha_file"
    (cd "$OUTPUT_DIR" && shasum -a 256 -c "$(basename "$dmg_sha_file")" >/dev/null) \
      || fail "SHA-256 round-trip verification failed for $(basename "$dmg_artifact")"

    ARTIFACT="$(basename "$dmg_artifact")" APP_NAME="Vamp Sync" BUNDLE_ID="$bundle_id" \
      VERSION="$version" BUILD="$build" ARCHS="$ARCHS" SHA256="$dmg_sha256" SIZE="$dmg_size" \
      COMMIT="$COMMIT" TREE_STATE="$tree_state" MANIFEST="$dmg_manifest" \
      python3 - <<'PY'
import datetime
import json
import os

payload = {
    "schemaVersion": 1,
    "artifact": os.environ["ARTIFACT"],
    "application": os.environ["APP_NAME"],
    "platform": "macOS",
    "minimumOSVersion": "13.0",
    "version": os.environ["VERSION"],
    "build": os.environ["BUILD"],
    "bundleIdentifier": os.environ["BUNDLE_ID"],
    "architecture": os.environ["ARCHS"].split(),
    "signature": "ad-hoc",
    "appleNotarized": False,
    "sourceRepository": "https://github.com/Mesutcydev/vamp-suite",
    "sourceCommit": os.environ["COMMIT"],
    "sourceTreeState": os.environ["TREE_STATE"],
    "sha256": os.environ["SHA256"],
    "sizeBytes": int(os.environ["SIZE"]),
    "createdAt": datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
}
with open(os.environ["MANIFEST"], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

    "$ROOT/scripts/generate-vamp-sbom.sh" \
      "$dmg_artifact" "$package_kind" "$version" "$build" "$COMMIT" "$dmg_sbom"
    log "Created $(basename "$dmg_artifact")"
    log "SHA-256 $dmg_sha256"
  fi
}

# Keep the scheme, bundle ID, and storage identity stable for existing installs.
package_host "VampMiniHost" "Vamp Sync" "com.mesutcy.remotedesktop.minhost" "VampSync"

log "Host artifacts are ready in $OUTPUT_DIR"
