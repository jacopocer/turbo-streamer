#!/bin/bash
# Builds both apps, zips them, and publishes them to the Turbo server so every
# installed copy can self-update. Writes the appcast manifest turbolink serves.
#
# Server work is the owner's to authorize: run this only when he asks. It writes
# only under /opt/turbolink/downloads and /opt/turbolink/api, and restarts
# turbolink-api (pairing sessions survive: turbolink flushes them on SIGTERM).
#
# Usage: deploy-apps.sh [--dry-run] ["release notes"]
#   --dry-run   build, zip and run every check; write the appcast and the zips to
#               .deploy-dry-run/ and touch no server.
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

HOST="${TURBOLINK_DEPLOY_HOST:-root@136.244.104.119}"
SSH_KEY="${TURBOLINK_SSH_KEY:-$HOME/.ssh/id_ed25519}"
BASE_URL="${TURBOLINK_BASE_URL:-https://turbostreamer.indigital.tv}"

DRY_RUN="no"; NOTES=""
for a in "$@"; do
    case "$a" in
        --dry-run) DRY_RUN="yes" ;;
        --*)       echo "unknown option: $a" >&2; exit 2 ;;
        *)         if [ -z "$NOTES" ]; then NOTES="$a"; else echo "one notes argument only (got a second: $a)" >&2; exit 2; fi ;;
    esac
done
ssh_do() { ssh -i "$SSH_KEY" "$HOST" "$@"; }
fail() { echo "‼️   $*" >&2; exit 1; }
refuse() { if [ "$DRY_RUN" = "yes" ]; then echo "⚠️   $* (allowed in --dry-run only)"; else fail "$*"; fi; }

VERSION="$(cat VERSION)"
BUILD="$(git rev-list --count HEAD)"
echo "== apps v$VERSION build $BUILD$( [ "$DRY_RUN" = yes ] && echo ' — DRY RUN, no server is touched' || true ) =="

# The build number is the commit count, and installed apps update only to a HIGHER
# number. Publishing uncommitted work, or a number already out there, ships bytes
# that match no commit and that existing installs would never pick up.
[ -z "$(git status --porcelain)" ] || refuse "uncommitted changes — commit first (the build number is the commit count)"
PUBLISHED="$(curl -fsS --max-time 10 "$BASE_URL/v1/appcast" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(max([v["build"] for v in d.values() if isinstance(v, dict) and "build" in v] or [0]))
except Exception:
    print(0)' 2>/dev/null || echo 0)"
[ "$BUILD" -gt "$PUBLISHED" ] || refuse "build $BUILD is not newer than the published build $PUBLISHED — installed apps would ignore it"

# Every published build carries the newest NDI SDK.
receiver/ndi/ndi-sdk.sh check || refuse "the NDI SDK on this Mac is not the latest — run receiver/ndi/ndi-sdk.sh update"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
zipapp() { /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$1" "$2"; }

STREAMER_ZIP="TurboStreamer-$BUILD.zip"
RECEIVER_ZIP="TurboReceiver-$BUILD.zip"

./net/build-net.sh >/dev/null
./build.sh >/dev/null
./receiver/build.sh >/dev/null
zipapp "Turbo Streamer.app" "$WORK/$STREAMER_ZIP"
zipapp "receiver/Turbo Receiver.app" "$WORK/$RECEIVER_ZIP"

# ── Check what is actually inside each zip ─────────────────────────────────────
# On the extracted zip rather than the tree: the folder name must be the one the
# updater replaces, and every helper must find its libraries inside the bundle.
check_zip() {   # <zip> <expected bundle name>
    local d="$WORK/check-${2// /_}" app bin
    mkdir -p "$d"; /usr/bin/ditto -x -k "$1" "$d"
    app="$d/$2"
    [ -d "$app" ] || fail "$(basename "$1"): expected '$2' inside, found: $(ls "$d" | tr '\n' ' ')"
    bin="$app/Contents/Resources/bin"
    DYLD_LIBRARY_PATH="$bin/lib" "$bin/ffmpeg" -hide_banner -version >/dev/null 2>&1 \
        || fail "$(basename "$1"): the bundled ffmpeg does not run"
    ./vendor/copy-dylibs.sh verify "$bin/lib" "$bin" >/dev/null || fail "$(basename "$1"): bundle is not self-contained"
}
check_zip "$WORK/$STREAMER_ZIP" "Turbo Streamer.app"
check_zip "$WORK/$RECEIVER_ZIP" "Turbo Receiver.app"
echo "✅  zips checked: right bundle names, ffmpeg runs, self-contained"

# ── Appcast, as real JSON (notes are free text and may contain quotes) ────────
A_VERSION="$VERSION" A_BUILD="$BUILD" A_BASE="$BASE_URL" A_NOTES="$NOTES" \
A_STREAMER="$STREAMER_ZIP" A_STREAMER_SHA="$(sha "$WORK/$STREAMER_ZIP")" \
A_RECEIVER="$RECEIVER_ZIP" A_RECEIVER_SHA="$(sha "$WORK/$RECEIVER_ZIP")" \
python3 - > "$WORK/appcast.json" <<'PY'
import json, os
e = os.environ
base, build = e["A_BASE"], int(e["A_BUILD"])
def entry(name, sha):
    return {"version": e["A_VERSION"], "build": build,
            "url": f"{base}/downloads/{name}", "sha256": sha, "notes": e["A_NOTES"]}
print(json.dumps({"streamer": entry(e["A_STREAMER"], e["A_STREAMER_SHA"]),
                  "receiver": entry(e["A_RECEIVER"], e["A_RECEIVER_SHA"])},
                 indent=2, ensure_ascii=False))
PY

UPLOAD=("$WORK/$STREAMER_ZIP" "$WORK/$RECEIVER_ZIP")

if [ "$DRY_RUN" = "yes" ]; then
    OUT="$PWD/.deploy-dry-run"; rm -rf "$OUT"; mkdir -p "$OUT"
    cp "${UPLOAD[@]}" "$WORK/appcast.json" "$OUT/"
    echo "== dry run: would upload, in this order =="
    for f in "${UPLOAD[@]}"; do echo "   $(basename "$f")  ($(du -h "$f" | cut -f1))"; done
    echo "   link-server/index.js  + restart turbolink-api + health check"
    echo "   appcast.json  (last)"
    echo "   artefacts copied to $OUT"
    exit 0
fi

# ── Publish, in an order where the appcast never points at something not yet live ─
# 1. the files the new appcast will name
ssh_do "mkdir -p /opt/turbolink/downloads"
scp -i "$SSH_KEY" "${UPLOAD[@]}" "$HOST:/opt/turbolink/downloads/"
# 2. the turbolink that serves them, restarted and checked
scp -i "$SSH_KEY" link-server/index.js "$HOST:/opt/turbolink/api/index.js"
ssh_do "chown -R www-data:www-data /opt/turbolink/downloads /opt/turbolink/api/index.js && systemctl restart turbolink-api"
sleep 2
ssh_do "curl -fsS -m 5 http://127.0.0.1:8814/health" >/dev/null \
    || fail "turbolink is not healthy after the restart — appcast NOT updated; the previous one is still live"
# 3. the appcast last, swapped in atomically
scp -i "$SSH_KEY" "$WORK/appcast.json" "$HOST:/opt/turbolink/downloads/appcast.json.new"
ssh_do "chown www-data:www-data /opt/turbolink/downloads/appcast.json.new && mv /opt/turbolink/downloads/appcast.json.new /opt/turbolink/downloads/appcast.json"

echo "== verify =="
curl -fsS "$BASE_URL/v1/appcast" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("appcast parses:", {k: v.get("build") for k, v in d.items() if isinstance(v, dict) and "build" in v})'
for f in "${UPLOAD[@]}"; do
    # GET only (the route has no HEAD); abort after the headers, the status is all we need.
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$BASE_URL/downloads/$(basename "$f")" || true)"
    echo "   $(basename "$f") -> $code"
    [ "$code" = "200" ] || fail "$(basename "$f") is not served"
done
echo "== done: v$VERSION build $BUILD published =="
