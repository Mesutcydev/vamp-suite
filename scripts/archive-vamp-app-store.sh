#!/usr/bin/env bash
# Both editions are compiled from the same specs and sources. Store delivery
# uses Xcode archives; the website DMG/IPA packagers remain independent.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT="${1:-all}"
[[ $# -gt 0 ]] && shift
TEAM=""
UNSIGNED=0
PROFILE=""
SIGNING_IDENTITY="Apple Distribution"
ARCHIVE_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --team) TEAM="${2:?Missing team identifier}"; shift 2 ;;
    --unsigned) UNSIGNED=1; shift ;;
    --distribution-profile) PROFILE="${2:?Missing profile name or UUID}"; shift 2 ;;
    --signing-identity) SIGNING_IDENTITY="${2:?Missing signing identity}"; shift 2 ;;
    --archive-path) ARCHIVE_PATH="${2:?Missing archive path}"; shift 2 ;;
    *) echo "Usage: $0 [sync|stream|control|all] [--team TEAM_ID | --unsigned] [--distribution-profile NAME_OR_UUID] [--signing-identity IDENTITY] [--archive-path PATH]" >&2; exit 2 ;;
  esac
done
[[ "$PRODUCT" == sync || "$PRODUCT" == stream || "$PRODUCT" == control || "$PRODUCT" == all ]] || exit 2
if [[ "$PRODUCT" == all && ( -n "$PROFILE" || -n "$ARCHIVE_PATH" ) ]]; then
  echo 'Choose one product when supplying a profile or archive path.' >&2; exit 2
fi
VERIFY_PROFILE=()
if [[ "$UNSIGNED" == 1 ]]; then
  [[ -z "$PROFILE" ]] || { echo '--unsigned cannot use a distribution profile.' >&2; exit 2; }
  SIGNING=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
else
  [[ -n "$TEAM" ]] || { echo 'Pass your Apple Developer team with --team, or --unsigned for compile verification.' >&2; exit 2; }
  if [[ -n "$PROFILE" ]]; then
    SIGNING=("DEVELOPMENT_TEAM=$TEAM" CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY")
    if [[ "$PRODUCT" == control ]]; then
      SIGNING+=("VAMP_CONTROL_DISTRIBUTION_PROFILE=$PROFILE")
    else
      SIGNING+=("PROVISIONING_PROFILE_SPECIFIER=$PROFILE")
    fi
    VERIFY_PROFILE=(--require-distribution-profile)
  else
    SIGNING=("DEVELOPMENT_TEAM=$TEAM" CODE_SIGN_STYLE=Automatic)
  fi
fi
cd "$ROOT"
mkdir -p dist/AppStore
archive() {
  local product="$1" spec project scheme configuration destination bundle archive_path
  if [[ "$product" == sync ]]; then
    spec=project.yml; project=RemoteDesktopToolApps.xcodeproj; scheme=VampSyncAppStore
    configuration=Release; destination='generic/platform=macOS'; bundle='Vamp Sync.app'
  elif [[ "$product" == stream ]]; then
    spec=vampstream-project.yml; project=VampStream.xcodeproj; scheme=VampStreamAppStore
    configuration=AppStore; destination='generic/platform=iOS'; bundle='App Stream.app'
  else
    spec=macclient-appstore-project.yml; project=MacClient-AppStore.xcodeproj; scheme=MacClientAppStore
    configuration=Release; destination='generic/platform=macOS'; bundle='Vamp Control.app'
  fi
  archive_path="${ARCHIVE_PATH:-dist/AppStore/$scheme.xcarchive}"
  xcodegen generate --spec "$spec"
  xcodebuild -project "$project" -scheme "$scheme" -configuration "$configuration" \
    -destination "$destination" -archivePath "$archive_path" \
    "${SIGNING[@]}" archive
  python3 scripts/verify-vamp-store-bundle.py "$product" \
    "$archive_path/Products/Applications/$bundle" ${VERIFY_PROFILE[@]+"${VERIFY_PROFILE[@]}"}
}
if [[ "$PRODUCT" == all ]]; then archive sync; archive stream; archive control; else archive "$PRODUCT"; fi
