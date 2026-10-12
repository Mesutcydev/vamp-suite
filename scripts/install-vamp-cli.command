#!/usr/bin/env bash

set -euo pipefail

APP=""
for candidate in "/Applications/Vamp Host.app" "/Applications/Vamp Terminal Host.app"; do
  if [[ -f "$candidate/Contents/Resources/vamp" ]]; then
    APP="$candidate"
    break
  fi
done

if [[ -z "$APP" ]]; then
  printf 'Vamp Host or Vamp Terminal Host is not installed in /Applications.\n' >&2
  printf 'Drag one of the host apps to Applications, open it once, then run this installer again.\n' >&2
  read -r -p "Press Return to close…" _
  exit 1
fi

SOURCE="$APP/Contents/Resources/vamp"
DESTINATION="/usr/local/bin/vamp"

sudo mkdir -p /usr/local/bin
sudo ln -sf "$SOURCE" "$DESTINATION"

printf '\nInstalled: %s\n' "$DESTINATION"
"$DESTINATION" version || true
printf '\nAgents can now run: vamp status --json\n'
read -r -p "Press Return to close…" _
