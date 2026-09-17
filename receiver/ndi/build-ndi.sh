#!/bin/bash
# Builds ndi-sender / ndi-find against the NDI SDK headers and the installed
# NDI runtime (/usr/local/lib/libndi.dylib, provided by NDI Tools).
# Point NDI_SDK_DIR at the headers if they live somewhere else.
set -euo pipefail
cd "$(dirname "$0")"

CANDIDATES=(
    "${NDI_SDK_DIR:-}"
    "$HOME/obs-ops/external/DistroAV/lib/ndi"
    "/Library/NDI SDK for Apple/include"
)
INC=""
for c in "${CANDIDATES[@]}"; do
    [ -n "$c" ] && [ -f "$c/Processing.NDI.Lib.h" ] && { INC="$c"; break; }
done
[ -n "$INC" ] || { echo "NDI SDK headers not found. Set NDI_SDK_DIR." >&2; exit 1; }
[ -f /usr/local/lib/libndi.dylib ] || { echo "NDI runtime missing — install NDI Tools." >&2; exit 1; }

echo "🔨  headers: $INC"
mkdir -p bin
for t in ndi-sender ndi-find; do
    # Look for libndi next to the binary first (bundled inside the .app), then
    # fall back to the system copy installed by NDI Tools.
    clang -O2 -Wall -I"$INC" "$t.c" -L/usr/local/lib -lndi \
          -Wl,-rpath,@loader_path/lib -Wl,-rpath,/usr/local/lib -o "bin/$t"
    echo "✅  bin/$t"
done
