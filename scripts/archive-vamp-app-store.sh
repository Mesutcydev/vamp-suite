#!/usr/bin/env bash
# Both editions are compiled from the same specs and sources. Store delivery
# uses Xcode archives; the website DMG/IPA packagers remain independent.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT="${1:-all}"
[[ $# -gt 0 ]] && shift
TEAM=""
UNSIGNED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --team) TEAM="${2:?Missing team identifier}"; shift 2 ;;
    --unsigned) UNSIGNED=1; shift ;;
    *) echo "Usage: $0 [sync|stream|all] [--team TEAM_ID | --unsigned]" >&2; exit 2 ;;
  esac
done
[[ "$PRODUCT" == sync || "$PRODUCT" == stream || "$PRODUCT" == all ]] || exit 2
if [[ "$UNSIGNED" == 1 ]]; then
  SIGNING=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
else
  [[ -n "$TEAM" ]] || { echo 'Pass your Apple Developer team with --team, or --unsigned for compile verification.' >&2; exit 2; }
  SIGNING=("DEVELOPMENT_TEAM=$TEAM" CODE_SIGN_STYLE=Automatic)
fi
cd "$ROOT"
mkdir -p dist/AppStore
archive() {
  local product="$1" spec project scheme configuration destination bundle
  if [[ "$product" == sync ]]; then
    spec=project.yml; project=RemoteDesktopToolApps.xcodeproj; scheme=VampSyncAppStore
    configuration=Release; destination='generic/platform=macOS'; bundle='App Sync.app'
  else
    spec=vampstream-project.yml; project=VampStream.xcodeproj; scheme=VampStreamAppStore
    configuration=AppStore; destination='generic/platform=iOS'; bundle='App Stream.app'
  fi
  xcodegen generate --spec "$spec"
  xcodebuild -project "$project" -scheme "$scheme" -configuration "$configuration" \
    -destination "$destination" -archivePath "dist/AppStore/$scheme.xcarchive" \
    "${SIGNING[@]}" archive
  python3 scripts/verify-vamp-store-bundle.py "$product" \
    "dist/AppStore/$scheme.xcarchive/Products/Applications/$bundle"
}
if [[ "$PRODUCT" == all ]]; then archive sync; archive stream; else archive "$PRODUCT"; fi
