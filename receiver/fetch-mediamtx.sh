#!/bin/bash
# Downloads the MediaMTX binary into receiver/vendor/ (not tracked in git).
# MediaMTX is a single static Go binary, MIT licensed — no Homebrew needed.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p vendor

ARCH="$(uname -m)"
case "$ARCH" in
    arm64)  ASSET="darwin_arm64" ;;
    x86_64) ASSET="darwin_amd64" ;;
    *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac

echo "🔎  Looking up latest MediaMTX release ($ASSET)…"
URL=$(curl -sL https://api.github.com/repos/bluenviron/mediamtx/releases/latest \
      | grep -o "https://[^\"]*${ASSET}\.tar\.gz" | head -1)
[ -n "$URL" ] || { echo "Could not resolve release URL" >&2; exit 1; }

echo "⬇️   $URL"
TMP=$(mktemp -d)
curl -sL "$URL" -o "$TMP/mtx.tar.gz"
tar xzf "$TMP/mtx.tar.gz" -C "$TMP"
mv "$TMP/mediamtx" vendor/mediamtx
cp "$TMP/LICENSE" vendor/mediamtx.LICENSE 2>/dev/null || true
chmod +x vendor/mediamtx
rm -rf "$TMP"

echo "✅  vendor/mediamtx $(./vendor/mediamtx --version 2>/dev/null)"
