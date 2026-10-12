#!/usr/bin/env bash
# Stable public entry point for the Vamp Sync artifact produced by the host packager.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/package-vamp-hosts.sh" --only VampMiniHost --output-dir dist/VampStreamHost "$@"
printf '[vamp-sync] Vamp Sync DMG and checksum are in dist/VampStreamHost.\n'
