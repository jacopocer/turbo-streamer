#!/bin/bash
# Deploys turbolink to the production box.
#
# Server work is the owner's to authorize — run this only when he explicitly
# asks for this deploy. It installs a NEW service (/opt/turbolink, port 8814,
# turbostreamer.indigital.tv) and touches nothing that already runs on the box.
set -euo pipefail
cd "$(dirname "$0")/.."

HOST="${TURBOLINK_DEPLOY_HOST:-root@136.244.104.119}"
SSH_KEY="${TURBOLINK_SSH_KEY:-$HOME/.ssh/id_ed25519}"
DOMAIN="${TURBOLINK_DOMAIN:-turbostreamer.indigital.tv}"
ssh_do() { ssh -i "$SSH_KEY" "$HOST" "$@"; }

echo "== turbolink deploy → $HOST ($DOMAIN) =="

ssh_do "mkdir -p /opt/turbolink/api /opt/turbolink/data"
scp -i "$SSH_KEY" index.js "$HOST:/opt/turbolink/api/index.js"
scp -i "$SSH_KEY" deploy/turbolink-api.service "$HOST:/etc/systemd/system/turbolink-api.service"
scp -i "$SSH_KEY" deploy/turbolink.nginx "$HOST:/tmp/turbolink.nginx"

ssh_do "chown -R www-data:www-data /opt/turbolink && chmod 700 /opt/turbolink/data"
# Rate-limit zone as its own file in conf.d (included inside the http block).
# Editing the shared nginx.conf in place on a box that runs five other apps is
# not worth the risk.
ssh_do "printf 'limit_req_zone \$binary_remote_addr zone=turbolink:10m rate=10r/s;\n' > /etc/nginx/conf.d/turbolink-limit.conf"
# The final vhost references a certificate that does not exist yet, so enabling
# it first would make `nginx -t` fail and take the reload down with it — on a box
# running five other apps. Order: HTTP-only vhost, then the cert, then the real one.
if ! ssh_do "test -d /etc/letsencrypt/live/$DOMAIN"; then
    ssh_do "cat > /etc/nginx/sites-available/turbolink <<'HTTPONLY'
server {
    listen 80;
    server_name $DOMAIN;
    location / { return 200 'turbolink bootstrap'; add_header content-type text/plain; }
}
HTTPONLY"
    ssh_do "ln -sf /etc/nginx/sites-available/turbolink /etc/nginx/sites-enabled/turbolink"
    ssh_do "nginx -t && systemctl reload nginx"
    ssh_do "certbot certonly --nginx -d $DOMAIN --non-interactive --agree-tos -m jacopocerati@gmail.com"
fi

# Now the certificate exists: install the real vhost.
ssh_do "cp /tmp/turbolink.nginx /etc/nginx/sites-available/turbolink && rm -f /tmp/turbolink.nginx"
ssh_do "ln -sf /etc/nginx/sites-available/turbolink /etc/nginx/sites-enabled/turbolink"

ssh_do "systemctl daemon-reload && systemctl enable --now turbolink-api && systemctl restart turbolink-api"
ssh_do "nginx -t && systemctl reload nginx"

echo "== health check =="
ssh_do "curl -fsS http://127.0.0.1:8814/health" && echo
curl -fsS "https://$DOMAIN/health" && echo
echo "== done =="
