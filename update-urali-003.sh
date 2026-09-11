#!/usr/bin/env bash
# urali update 003: spam protection + analytics, tighter API routes, QA run, then page update.
set -euo pipefail
REPO_RAW="https://raw.githubusercontent.com/anup-aws/urali-site/main"
DOMAIN=urali.anups.cloud
SITE=/etc/nginx/sites-available/urali
API_PORT=3100
log() { printf '\n==> %s\n' "$*"; }
fetch() {  # fetch a repo file from the root, or from server/ subfolders if organised that way
  local name=$1 out=$2
  curl -fsSL "$REPO_RAW/$name" -o "$out" 2>/dev/null \
    || curl -fsSL "$REPO_RAW/server/$name" -o "$out" 2>/dev/null \
    || curl -fsSL "$REPO_RAW/server/db/$name" -o "$out"
}
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
TMP=$(mktemp -d); chmod 755 "$TMP"

log "1/5 Applying database update 003"
fetch 003_urali_protection_analytics.sql "$TMP/003.sql"; chmod 644 "$TMP/003.sql"
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q -d urali -f "$TMP/003.sql" >/dev/null
echo "applied 003"
sleep 2

log "2/5 Tightening Nginx API routes and rate limits"
cat > /etc/nginx/conf.d/urali-ratelimit.conf <<'NGX'
limit_req_zone $binary_remote_addr zone=urali_reserve:10m rate=6r/m;
limit_req_zone $binary_remote_addr zone=urali_events:10m  rate=90r/m;
limit_req_zone $binary_remote_addr zone=urali_read:10m    rate=120r/m;
NGX
cp "$SITE" "$SITE.bak.$(date +%s)"
cat > "$SITE" <<NGX
server {
    server_name ${DOMAIN};
    root /var/www/urali;
    index index.html;

    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header X-Frame-Options "DENY" always;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Reservations: POST only, strict per-IP rate limit
    location = /api/rest/v1/rpc/create_reservation {
        limit_except POST { deny all; }
        limit_req zone=urali_reserve burst=4 nodelay;
        limit_req_status 429;
        client_max_body_size 8k;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header Host \$host;
        proxy_pass http://127.0.0.1:${API_PORT}/rpc/create_reservation;
    }

    # Analytics events: POST only, looser limit
    location = /api/rest/v1/rpc/log_event {
        limit_except POST { deny all; }
        limit_req zone=urali_events burst=30 nodelay;
        limit_req_status 429;
        client_max_body_size 4k;
        access_log off;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header Host \$host;
        proxy_pass http://127.0.0.1:${API_PORT}/rpc/log_event;
    }

    # Public read-only data
    location = /api/rest/v1/batches {
        limit_except GET { deny all; }
        limit_req zone=urali_read burst=40 nodelay;
        limit_req_status 429;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_pass http://127.0.0.1:${API_PORT}/batches;
    }
    location = /api/rest/v1/products {
        limit_except GET { deny all; }
        limit_req zone=urali_read burst=40 nodelay;
        limit_req_status 429;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_pass http://127.0.0.1:${API_PORT}/products;
    }

    # Everything else under /api is closed
    location /api/ {
        return 404;
    }

    listen [::]:443 ssl;
    listen 443 ssl;
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}
NGX
if nginx -t 2>&1 | tail -1; then
  systemctl reload nginx
  sleep 3
else
  echo "Nginx test failed, restoring previous config"
  cp "$(ls -t $SITE.bak.* | head -1)" "$SITE"; nginx -t && systemctl reload nginx; exit 1
fi

log "3/5 Running QA"
fetch qa-urali.sh "$TMP/qa.sh"
set +e
bash "$TMP/qa.sh"
QA_FAILS=$?
set -e

log "4/5 Updating the live page"
if [ "$QA_FAILS" -eq 0 ]; then
  fetch index.html "$TMP/index.html"
  if grep -q "p_elapsed_ms" "$TMP/index.html"; then
    install -m 644 "$TMP/index.html" /var/www/urali/index.html
    echo "live page updated"
  else
    echo "index.html on GitHub is the older version. Upload the new one and re-run this script."
  fi
else
  echo "QA had $QA_FAILS failure(s), so the live page was NOT updated."
fi

log "5/5 Latest real orders (phone numbers masked)"
runuser -u postgres -- psql -d urali -c "select code, to_char(created_at at time zone 'Asia/Kolkata','DD Mon HH24:MI') as created_ist, batch_id, status, customer_name, overlay(phone placing 'xxxxxx' from 4 for 6) as phone, area, boxes, total, coalesce(client->>'device','') as device, risk_flags from reservations where source <> 'qa' order by created_at desc limit 10;"
rm -rf "$TMP"
