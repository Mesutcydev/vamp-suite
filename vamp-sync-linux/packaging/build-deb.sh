#!/bin/sh
set -eu

if [ "$(uname -s)" != Linux ]; then
    printf '%s\n' "Build the Debian installer on Linux." >&2
    exit 1
fi

source_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repository=$(dirname -- "$source_dir")
output_dir=${1:-"$source_dir/build/installers"}
mkdir -p -- "$output_dir"
output_dir=$(CDPATH= cd -- "$output_dir" && pwd)

arch=$(go env GOARCH)
native_arch=$(dpkg --print-architecture)
case "$arch" in
    amd64|arm64) ;;
    *) printf 'Unsupported package architecture: %s\n' "$arch" >&2; exit 1 ;;
esac

stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
cd -- "$source_dir"
mkdir -p "$stage/DEBIAN"
install -d "$stage/usr/lib/vamp-sync" "$stage/usr/share/doc/vamp-sync-linux"
go build -trimpath -buildvcs=false -buildmode=pie -ldflags='-s -w' -o "$stage/usr/lib/vamp-sync/vamp-sync-linux" .
version=$(awk -F '"' '/^const version = "/ { print $2; exit }' diagnostics.go)
if [ "$arch" = "$native_arch" ] && [ "$version" != "$("$stage/usr/lib/vamp-sync/vamp-sync-linux" --version)" ]; then
    printf '%s\n' "The packaged host version does not match its source." >&2
    exit 1
fi
if [ -z "$version" ] || ! dpkg --validate-version "$version"; then
    printf '%s\n' "The host returned an invalid package version." >&2
    exit 1
fi

glibc=$("${VAMP_OBJDUMP:-objdump}" -T "$stage/usr/lib/vamp-sync/vamp-sync-linux" | sed -n 's/.*(GLIBC_\([0-9.]*\)).*/\1/p' | sort -V | tail -1)
if [ -z "$glibc" ]; then
    printf '%s\n' "Could not identify the minimum glibc version." >&2
    exit 1
fi

install -Dm755 packaging/vamp-sync "$stage/usr/bin/vamp-sync"
install -Dm644 desktop/vamp_sync.py "$stage/usr/lib/vamp-sync/desktop/vamp_sync.py"
install -Dm644 desktop/panel.css "$stage/usr/lib/vamp-sync/desktop/panel.css"
install -Dm644 desktop/vamp-sync.desktop "$stage/usr/share/applications/app.thevamp.SyncLinux.desktop"
assets=$repository/Sources/HostApp/Assets.xcassets
artwork=$stage/usr/share/vamp-sync/artwork
install -Dm644 "$assets/SyncBackdrop.imageset/sync-corridor.png" "$artwork/SyncBackdrop.imageset/sync-corridor.png"
install -Dm644 "$assets/VampSyncLogo.imageset/VampSyncLogo.png" "$artwork/VampSyncLogo.imageset/VampSyncLogo.png"
install -Dm644 "$assets/VampSyncIcon.appiconset/icon_128.png" "$stage/usr/share/icons/hicolor/128x128/apps/vamp-sync.png"
install -m644 README.md TESTING.md "$repository/LICENSE" "$repository/NOTICE" "$stage/usr/share/doc/vamp-sync-linux/"

cat > "$stage/DEBIAN/control" <<CONTROL
Package: vamp-sync-linux
Version: $version
Section: net
Priority: optional
Architecture: $arch
Maintainer: Mesut Can Yağcı <mesutcydev@gmail.com>
Depends: libc6 (>= $glibc), libssl3 | libssl3t64, libx11-6, libx11-xcb1, libxcb1, libxcb-composite0, libxcb-xtest0, libxcb-screensaver0, ffmpeg, python3 (>= 3.9), python3-gi, gir1.2-gtk-3.0, librsvg2-common, shared-mime-info, qrencode, iproute2, avahi-utils
Recommends: adwaita-icon-theme, avahi-daemon, xclip, libgtk-3-bin
Homepage: https://thevamp.app/sync/
Description: Native Linux host for Vamp Control and Vamp Stream
 Private peer pairing and encrypted desktop or application-window streaming
 with an X11 and GTK desktop panel. Supports remote pointer and keyboard
 control, trusted devices, and diagnostic reports.
CONTROL

dpkg-deb --root-owner-group --build "$stage" "$output_dir/vamp-sync-linux_${version}_${arch}.deb"
