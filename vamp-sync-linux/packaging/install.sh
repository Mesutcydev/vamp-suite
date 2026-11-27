#!/bin/sh
set -eu

cd -- "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if ! command -v apt-get >/dev/null || ! command -v dpkg >/dev/null; then
    printf '%s\n' "This installer requires Debian 12, Ubuntu 24.04, or a newer compatible release." >&2
    exit 1
fi

arch=$(dpkg --print-architecture)
case "$arch" in
    amd64|arm64) ;;
    *) printf 'Unsupported Linux architecture: %s\n' "$arch" >&2; exit 1 ;;
esac

sha256sum -c SHA256SUMS
set -- "$PWD"/vamp-sync-linux_*_"$arch".deb
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    printf 'Expected exactly one installer for %s.\n' "$arch" >&2
    exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
    exec apt-get install "$1"
fi
exec sudo apt-get install "$1"
