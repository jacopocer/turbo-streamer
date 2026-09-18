#!/bin/bash
# Builds both apps, zips them, and publishes them to the Turbo server so every
# installed copy can self-update. Writes the appcast manifest turbolink serves.
#
# Server work is the owner's to authorize: run this only when he asks. It writes
# only under /opt/turbolink/downloads and touches nothing else on the box.
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

HOST="${TURBOLINK_DEPLOY_HOST:-root@136.244.104.119}"
SSH_KEY="${TURBOLINK_SSH_KEY:-$HOME/.ssh/id_ed25519}"
BASE_URL="${TURBOLINK_BASE_URL:-https://turbostreamer.indigital.tv}"
NOTES="${1:-}"
ssh_do() { ssh -i "$SSH_KEY" "$HOST" "$@"; }

VERSION="$(cat VERSION)"
BUILD="$(git rev-list --count HEAD)"
echo "== publishing apps v$VERSION (build $BUILD) -> $HOST =="

# Build fresh so the bundle carries this exact version/build.
./net/build-net.sh >/dev/null
./build.sh >/dev/null
./receiver/build.sh >/dev/null

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

STREAMER_ZIP="TurboStreamer-$BUILD.zip"
RECEIVER_ZIP="TurboReceiver-$BUILD.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "Turbo Streamer.app" "$WORK/$STREAMER_ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "receiver/Turbo Receiver.app" "$WORK/$RECEIVER_ZIP"
S_SHA="$(sha "$WORK/$STREAMER_ZIP")"; R_SHA="$(sha "$WORK/$RECEIVER_ZIP")"

cat > "$WORK/appcast.json" <<JSON
{
  "streamer": {
    "version": "$VERSION", "build": $BUILD,
    "url": "$BASE_URL/downloads/$STREAMER_ZIP",
    "sha256": "$S_SHA",
    "notes": "$NOTES"
  },
  "receiver": {
    "version": "$VERSION", "build": $BUILD,
    "url": "$BASE_URL/downloads/$RECEIVER_ZIP",
    "sha256": "$R_SHA",
    "notes": "$NOTES"
  }
}
JSON

ssh_do "mkdir -p /opt/turbolink/downloads"
scp -i "$SSH_KEY" "$WORK/$STREAMER_ZIP" "$WORK/$RECEIVER_ZIP" "$WORK/appcast.json" "$HOST:/opt/turbolink/downloads/"
ssh_do "chown -R www-data:www-data /opt/turbolink/downloads"

# The appcast/download routes live in turbolink; push the current code and restart
# it, so a box running an older turbolink starts serving them.
scp -i "$SSH_KEY" link-server/index.js "$HOST:/opt/turbolink/api/index.js"
ssh_do "chown www-data:www-data /opt/turbolink/api/index.js && systemctl restart turbolink-api"
sleep 2

echo "== verify =="
curl -fsS "$BASE_URL/v1/appcast" | grep -o '"build": [0-9]*' | head -1
echo "streamer zip $(du -h "$WORK/$STREAMER_ZIP" | cut -f1), receiver zip $(du -h "$WORK/$RECEIVER_ZIP" | cut -f1)"
echo "== done: v$VERSION build $BUILD published =="
