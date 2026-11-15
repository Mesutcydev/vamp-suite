#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
destination="$1"
mkdir -p "$destination"
# Only website files belong in the Pages artifact. The rest of docs is kept for
# repository readers and release history.
rsync -a \
  --include='/index.html' --include='/404.html' \
  --include='/about/***' --include='/contact/***' --include='/privacy/***' \
  --include='/sync/***' --include='/mini-host/***' \
  --include='/agent-manifest.json' --include='/release.json' \
  --include='/llms.txt' --include='/robots.txt' --include='/sitemap.xml' \
  --include='/assets/' --include='/assets/site.*' --include='/assets/products.css' \
  --include='/assets/arcade.css' --include='/assets/arcade/***' \
  --include='/assets/favicon.svg' --include='/assets/vamp-control-logo.png' \
  --include='/assets/sync-loggia.png' --include='/assets/sync-symbol.svg' \
  --include='/assets/vamp-garden-engraving.jpg' --include='/assets/toile-terrace.jpg' \
  --include='/assets/previews/' --include='/assets/previews/vamp-control-ios-remote.png' \
  --exclude='*' \
  "$root/docs/" "$destination/"
