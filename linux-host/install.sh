#!/bin/sh
set -eu

SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/vamp-terminal-host"
BIN_DIR="${HOME}/.local/bin"
SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$SYSTEMD_DIR"
cp "$SOURCE_DIR/vamp_terminal_host.py" "$SOURCE_DIR/index.html" "$INSTALL_DIR/"
chmod 755 "$INSTALL_DIR/vamp_terminal_host.py"

sed "s|@INSTALL_DIR@|$INSTALL_DIR|g" "$SOURCE_DIR/vamp-terminal-host" > "$BIN_DIR/vamp-terminal-host"
chmod 755 "$BIN_DIR/vamp-terminal-host"
sed "s|@BIN_PATH@|$BIN_DIR/vamp-terminal-host|g" "$SOURCE_DIR/vamp-terminal-host.service" > "$SYSTEMD_DIR/vamp-terminal-host.service"

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload >/dev/null 2>&1 || true
fi

printf '%s\n' "Vamp Terminal Host installed."
printf '%s\n' "Run: $BIN_DIR/vamp-terminal-host"
printf '%s\n' "Start at login: systemctl --user enable --now vamp-terminal-host.service"
