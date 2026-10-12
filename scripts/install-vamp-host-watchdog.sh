#!/usr/bin/env bash

# Installs the optional Vamp Host watchdog as a per-user launch agent.
# No administrator access or public network exposure is required.

set -euo pipefail

watchdog_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
watchdog_source="$watchdog_root/scripts/vamp-host-watchdog"
watchdog_install_dir="$HOME/Library/Application Support/Vamp Watchdog"
watchdog_executable="$watchdog_install_dir/vamp-host-watchdog"
watchdog_agent_dir="$HOME/Library/LaunchAgents"
watchdog_plist="$watchdog_agent_dir/com.mesutcy.remotedesktop.host.watchdog.plist"
watchdog_domain="gui/$(id -u)"
watchdog_label="com.mesutcy.remotedesktop.host.watchdog"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "$watchdog_domain" "$watchdog_plist" 2>/dev/null || true
  rm -f "$watchdog_plist" "$watchdog_executable"
  printf '[vamp-watchdog] Uninstalled. Existing host data and logs were preserved.\n'
  exit 0
fi

printf '[vamp-watchdog] Vamp Host is discontinued. Only --uninstall remains supported.\n' >&2
exit 1
