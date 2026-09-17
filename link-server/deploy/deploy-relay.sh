#!/bin/bash
# Deploys the Turbo relay (MediaMTX) next to turbolink on the production box,
# and refreshes turbolink itself (it now issues relay credentials and answers
# MediaMTX's auth calls).
#
# Server work is the owner's to authorize: run this only when he explicitly
# asks. It adds ONE service (/opt/turborelay, unit turborelay, UDP 8890 and
# TCP 1935 opened in the host firewall) and restarts turbolink-api. Nothing
# else on the box is touched; nginx is not reloaded.
set -euo pipefail
cd "$(dirname "$0")/.."

HOST="${TURBOLINK_DEPLOY_HOST:-root@136.244.104.119}"
SSH_KEY="${TURBOLINK_SSH_KEY:-$HOME/.ssh/id_ed25519}"
MTX_VERSION="${MTX_VERSION:-v1.21.0}"     # same as receiver/vendor
MTX_URL="https://github.com/bluenviron/mediamtx/releases/download/${MTX_VERSION}/mediamtx_${MTX_VERSION}_linux_amd64.tar.gz"
ssh_do() { ssh -i "$SSH_KEY" "$HOST" "$@"; }

echo "== turborelay deploy → $HOST (MediaMTX $MTX_VERSION) =="

# turbolink first: the relay's auth calls land on it.
scp -i "$SSH_KEY" index.js "$HOST:/opt/turbolink/api/index.js"
scp -i "$SSH_KEY" deploy/turbolink-api.service "$HOST:/etc/systemd/system/turbolink-api.service"
ssh_do "chown www-data:www-data /opt/turbolink/api/index.js"

# The binary: fetched on the box from the pinned release, only when missing or
# a different version, so a re-run is cheap.
ssh_do "mkdir -p /opt/turborelay"
if ! ssh_do "test -x /opt/turborelay/mediamtx && /opt/turborelay/mediamtx --version 2>/dev/null | grep -q '^${MTX_VERSION}\$'"; then
    ssh_do "cd /tmp && curl -fsSL '$MTX_URL' -o mtx.tar.gz && tar xzf mtx.tar.gz mediamtx LICENSE && mv mediamtx /opt/turborelay/mediamtx && mv LICENSE /opt/turborelay/LICENSE && rm -f mtx.tar.gz"
fi
scp -i "$SSH_KEY" deploy/turborelay.yml "$HOST:/opt/turborelay/mediamtx.yml"
scp -i "$SSH_KEY" deploy/turborelay.service "$HOST:/etc/systemd/system/turborelay.service"
ssh_do "chown -R www-data:www-data /opt/turborelay && chmod 755 /opt/turborelay/mediamtx"

# Host firewall: the two relay doors (duplicate rules are ignored).
ssh_do "ufw allow 8890/udp comment 'turborelay SRT' && ufw allow 1935/tcp comment 'turborelay RTMP'"

ssh_do "systemctl daemon-reload && systemctl restart turbolink-api && systemctl enable --now turborelay && systemctl restart turborelay"
sleep 2
echo "== health =="
ssh_do "systemctl is-active turbolink-api turborelay && curl -fsS http://127.0.0.1:8814/health && echo && ss -lun | grep -q ':8890 ' && echo 'SRT listener up' && ss -ltn | grep -q ':1935 ' && echo 'RTMP listener up'"
curl -fsS "https://turbostreamer.indigital.tv/health" && echo
# Closing the circle for the neighbours (asked by the garibaldi session): the
# turbolink restart and the ufw change must leave garibaldi-api untouched.
echo "== neighbours =="
ssh_do "curl -fsS -m 5 http://127.0.0.1:8789/api/health && echo ' garibaldi-api OK'"
for u in https://indigital.tv https://garibaldi.indigital.tv; do
    printf '%s → %s\n' "$u" "$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$u")"
done
echo "== done =="
