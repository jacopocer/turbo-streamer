#!/bin/bash
# Sets the Tailscale API token on the Turbo server so the apps get their join
# keys automatically (no per-machine login). Prompts for the token with hidden
# input and sends it over SSH stdin, so it never lands in your shell history,
# in `ps`, or in a file on this Mac.
#
# Also refreshes turbolink's code + unit, so the token is actually read and the
# key/appcast endpoints exist. Server work is the owner's to authorize.
set -euo pipefail
cd "$(dirname "$0")/.."   # link-server/

HOST="${TURBOLINK_DEPLOY_HOST:-root@136.244.104.119}"
SSH_KEY="${TURBOLINK_SSH_KEY:-$HOME/.ssh/id_ed25519}"
BASE_URL="${TURBOLINK_BASE_URL:-https://turbostreamer.indigital.tv}"
TAILNET="${TS_TAILNET:--}"
TAG="${TS_TAG:-tag:turbo}"
ssh_do() { ssh -i "$SSH_KEY" "$HOST" "$@"; }

read -rsp "Tailscale API access token (tskey-api-…): " TOKEN; echo
[ -n "$TOKEN" ] || { echo "No token entered — aborting."; exit 1; }
read -rp "Tailnet name [default '-' = the token's own tailnet]: " TN; TAILNET="${TN:--}"

echo "== refreshing turbolink code + unit =="
scp -i "$SSH_KEY" index.js "$HOST:/opt/turbolink/api/index.js"
scp -i "$SSH_KEY" deploy/turbolink-api.service "$HOST:/etc/systemd/system/turbolink-api.service"
ssh_do "chown www-data:www-data /opt/turbolink/api/index.js"

echo "== writing /opt/turbolink/tailnet.env (0600, token via stdin) =="
# printf is a bash builtin, so the token is never a separate process argument.
printf 'TS_API_TOKEN=%s\nTS_TAILNET=%s\nTS_TAG=%s\n' "$TOKEN" "$TAILNET" "$TAG" \
  | ssh -i "$SSH_KEY" "$HOST" "umask 077; cat > /opt/turbolink/tailnet.env && chown www-data:www-data /opt/turbolink/tailnet.env && chmod 600 /opt/turbolink/tailnet.env"

ssh_do "systemctl daemon-reload && systemctl restart turbolink-api"
sleep 2

echo "== verify (should mint a key, not 503) =="
code="$(curl -s -o /dev/null -w '%{http_code}' -m 15 -X POST "$BASE_URL/v1/tailnet/key" -H 'content-type: application/json' -d '{"app":"probe","host":"probe"}')"
if [ "$code" = "200" ]; then echo "OK — turbolink mints join keys now."
else echo "Got HTTP $code. If 401/403, the token or tailnet is wrong. If 503, the token wasn't read — check the unit's EnvironmentFile."; fi
echo "== done =="
