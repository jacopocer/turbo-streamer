#!/bin/bash
# Deploys turbolink to the production box.
#
# Server work is the owner's to authorize — run this only when he explicitly
# asks for this deploy. It installs a NEW service (/opt/turbolink, port 8814,
# turbo.indigital.tv) and touches nothing that already runs on the box.
set -euo pipefail
cd "$(dirname "$0")/.."

HOST="${TURBOLINK_DEPLOY_HOST:-root@136.244.104.119}"
SSH_KEY="${TURBOLINK_SSH_KEY:-$HOME/.ssh/id_ed25519}"
DOMAIN="${TURBOLINK_DOMAIN:-turbo.indigital.tv}"
ssh_do() { ssh -i "$SSH_KEY" "$HOST" "$@"; }

echo "== turbolink deploy → $HOST ($DOMAIN) =="

ssh_do "mkdir -p /opt/turbolink/api /opt/turbolink/data"
scp -i "$SSH_KEY" index.js "$HOST:/opt/turbolink/api/index.js"
scp -i "$SSH_KEY" deploy/turbolink-api.service "$HOST:/etc/systemd/system/turbolink-api.service"
scp -i "$SSH_KEY" deploy/turbolink.nginx "$HOST:/etc/nginx/sites-available/turbolink"

ssh_do "chown -R www-data:www-data /opt/turbolink && chmod 700 /opt/turbolink/data"
ssh_do "grep -q 'zone=turbolink' /etc/nginx/nginx.conf || sed -i 's|http {|http {\n    limit_req_zone \$binary_remote_addr zone=turbolink:10m rate=10r/s;|' /etc/nginx/nginx.conf"
ssh_do "ln -sf /etc/nginx/sites-available/turbolink /etc/nginx/sites-enabled/turbolink"

# TLS only on the first run, when no certificate exists yet.
ssh_do "test -d /etc/letsencrypt/live/$DOMAIN || certbot certonly --nginx -d $DOMAIN --non-interactive --agree-tos -m jacopocerati@gmail.com"

ssh_do "systemctl daemon-reload && systemctl enable --now turbolink-api && systemctl restart turbolink-api"
ssh_do "nginx -t && systemctl reload nginx"

echo "== health check =="
ssh_do "curl -fsS http://127.0.0.1:8814/health" && echo
curl -fsS "https://$DOMAIN/health" && echo
echo "== done =="
