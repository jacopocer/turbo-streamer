#!/bin/bash
# Builds ndi-sender / ndi-find against the NDI SDK headers and the newest libndi
# on this Mac. Keep the SDK current with ./ndi-sdk.sh update (which also runs this).
# Point NDI_SDK_DIR at the headers if they live somewhere else.
set -euo pipefail
cd "$(dirname "$0")"

CANDIDATES=(
    "${NDI_SDK_DIR:-}"
    "/Library/NDI SDK for Apple/include"      # the official SDK, kept current by ndi-sdk.sh
)
INC=""
for c in "${CANDIDATES[@]}"; do
    [ -n "$c" ] && [ -f "$c/Processing.NDI.Lib.h" ] && { INC="$c"; break; }
done
[ -n "$INC" ] || { echo "NDI SDK headers not found — run ./ndi-sdk.sh update (or set NDI_SDK_DIR)." >&2; exit 1; }
LIB="$(./ndi-sdk.sh lib)" || { echo "no libndi on this Mac — run ./ndi-sdk.sh update" >&2; exit 1; }
LIBDIR="$(dirname "$LIB")"

echo "🔨  headers: $INC · libndi: $LIB"
mkdir -p bin
for t in ndi-sender ndi-find; do
    # Look for libndi next to the binary first (bundled inside the .app), then
    # fall back to the copy it was linked against.
    clang -O2 -Wall -I"$INC" "$t.c" -L"$LIBDIR" -lndi \
          -Wl,-rpath,@loader_path/lib -Wl,-rpath,"$LIBDIR" -o "bin/$t"
    echo "✅  bin/$t"
done
