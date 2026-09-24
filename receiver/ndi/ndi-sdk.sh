#!/bin/bash
# Keeps the NDI SDK on this Mac current. Both apps bundle libndi.dylib, and
# ndi-sender / ndi-find are compiled against the SDK headers — so both come from
# the latest SDK NDI publishes.
#
#   ndi-sdk.sh check    0 = the SDK installed here is the one NDI publishes today,
#                       1 = a newer one is out (or this script never installed it),
#                       2 = NDI could not be reached to tell.
#   ndi-sdk.sh update   download the official package, refuse it unless it is
#                       signed by NDI, install it (macOS asks for your password),
#                       rebuild ndi-sender/ndi-find, record what was installed.
#   ndi-sdk.sh lib      print the newest libndi.dylib on this Mac (what to bundle).
set -euo pipefail
cd "$(dirname "$0")"

URL="https://downloads.ndi.tv/SDK/NDI_SDK_Mac/Install_NDI_SDK_v6_Apple.pkg"
SDK_DIR="/Library/NDI SDK for Apple"
STAMP="$PWD/.ndi-sdk-installed"   # ETag of the package last installed on this Mac (gitignored)

# NDI changes the package's ETag whenever it publishes a new SDK.
remote_etag() {
    curl -fsSI --max-time 10 "$URL" 2>/dev/null | tr -d '\r' \
        | awk -F'"' 'tolower($1) ~ /^etag: / { print $2 }'
}
# "NDI SDK APPLE 12:49:04 Apr 13 2026 6.3.2.0" -> 6.3.2.0
lib_version() {
    { strings "$1" 2>/dev/null | grep -m1 -E '^NDI SDK APPLE .* [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | awk '{ print $NF }'; } || true
}
newest_lib() {
    local best="" bestv="" f v
    while IFS= read -r f; do
        v="$(lib_version "$f")"; [ -n "$v" ] || continue
        if [ -z "$bestv" ] || [ "$(printf '%s\n%s\n' "$bestv" "$v" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1)" != "$bestv" ]; then
            best="$f"; bestv="$v"
        fi
    done < <( { find "$SDK_DIR" -name libndi.dylib 2>/dev/null || true
                ls /usr/local/lib/libndi.dylib 2>/dev/null || true; } )   # either may be absent
    [ -n "$best" ] || return 1
    echo "$best"
}

cmd_check() {
    local r lib
    r="$(remote_etag)"
    if [ -z "$r" ]; then echo "⚠️   NDI SDK: could not reach NDI to check for a newer version"; return 2; fi
    if [ ! -f "$STAMP" ]; then
        echo "⚠️   NDI SDK: never installed by receiver/ndi/ndi-sdk.sh on this Mac — run: receiver/ndi/ndi-sdk.sh update"
        return 1
    fi
    if [ "$(cat "$STAMP")" != "$r" ]; then
        echo "⚠️   NDI SDK: a newer version is out — run: receiver/ndi/ndi-sdk.sh update"
        return 1
    fi
    lib="$(newest_lib || true)"
    echo "✅  NDI SDK is the latest published (libndi ${lib:+$(lib_version "$lib")})"
}

cmd_update() {
    local r tmp sig
    r="$(remote_etag)"
    [ -n "$r" ] || { echo "‼️   cannot reach $URL" >&2; exit 2; }
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    echo "⬇️   downloading the NDI SDK for Apple…"
    curl -fL# -o "$tmp/ndi.pkg" "$URL"
    # Only a package signed with NDI's own Apple developer ID gets installed.
    sig="$(pkgutil --check-signature "$tmp/ndi.pkg" 2>&1 || true)"
    if ! echo "$sig" | grep -q "signed by a developer certificate issued by Apple" \
       || ! echo "$sig" | grep -qE "Developer ID Installer: (NewTek|Vizrt)"; then
        echo "‼️   the package is not signed by NDI — not installing it:" >&2
        echo "$sig" >&2
        exit 1
    fi
    echo "🔐  installing (macOS will ask for your password)…"
    sudo installer -pkg "$tmp/ndi.pkg" -target /
    echo "$r" > "$STAMP"
    ./build-ndi.sh
    echo "✅  NDI SDK updated — libndi $(lib_version "$(newest_lib)")"
}

case "${1:-}" in
    check)  cmd_check ;;
    update) cmd_update ;;
    lib)    newest_lib ;;
    *)      echo "usage: $0 check|update|lib" >&2; exit 2 ;;
esac
