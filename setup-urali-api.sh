#!/usr/bin/env bash
# Sets up Postgres 16 + PostgREST for urali.anups.cloud on Ubuntu 24.04.
# Safe to re-run. Does not touch other Nginx sites.
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/anup-aws/urali-site/main"
DB=urali
API_PORT=3100
SITE=/etc/nginx/sites-available/urali
DOMAIN=urali.anups.cloud

log() { printf '\n==> %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }

log "1/7 Installing Postgres 16 and pg_cron"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq postgresql-16 postgresql-16-cron curl xz-utils openssl >/dev/null
systemctl enable --now postgresql

PGCONF=/etc/postgresql/16/main/postgresql.conf
if ! grep -q "^shared_preload_libraries = 'pg_cron'" "$PGCONF"; then
  printf "\n# urali\nshared_preload_libraries = 'pg_cron'\ncron.database_name = '%s'\ncron.timezone = 'UTC'\n" "$DB" >> "$PGCONF"
  systemctl restart postgresql
fi
# Postgres listens on localhost only (Ubuntu default); confirm:
grep -E "^#?listen_addresses" "$PGCONF" | head -1

log "2/7 Creating database and applying schema"
runuser -u postgres -- psql -qtAc "select 1 from pg_database where datname='$DB'" | grep -q 1 \
  || runuser -u postgres -- createdb "$DB"
TMP=$(mktemp -d)
chmod 755 "$TMP"
for f in 000_roles.sql 001_urali_core.sql 002_urali_schedules.sql; do
  curl -fsSL "$REPO_RAW/server/db/$f" -o "$TMP/$f"
  chmod 644 "$TMP/$f"
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$TMP/$f" >/dev/null
  echo "applied $f"
done

log "3/7 Setting the API database password (generated here, stored only in the config file)"
PASS=$(openssl rand -hex 24)
printf "alter role authenticator password '%s';\n" "$PASS" | runuser -u postgres -- psql -q -d "$DB"

log "4/7 Installing PostgREST"
if [ ! -x /usr/local/bin/postgrest ]; then
  URL=$(curl -fsSL https://api.github.com/repos/PostgREST/postgrest/releases/latest \
        | grep -oE '"browser_download_url": *"[^"]+linux-static-x(86-)?64\.tar\.xz"' | head -1 | cut -d'"' -f4)
  [ -n "$URL" ] || { echo "Could not find PostgREST release asset"; exit 1; }
  echo "downloading $URL"
  curl -fsSL "$URL" -o "$TMP/postgrest.tar.xz"
  tar -xJf "$TMP/postgrest.tar.xz" -C "$TMP"
  install -m 755 "$TMP/postgrest" /usr/local/bin/postgrest
fi
/usr/local/bin/postgrest --version || true
id postgrest >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin postgrest
mkdir -p /etc/postgrest
cat > /etc/postgrest/urali.conf <<CONF
db-uri = "postgres://authenticator:${PASS}@127.0.0.1:5432/${DB}"
db-schemas = "public"
db-anon-role = "anon"
server-host = "127.0.0.1"
server-port = ${API_PORT}
openapi-mode = "disabled"
CONF
chown root:postgrest /etc/postgrest/urali.conf
chmod 640 /etc/postgrest/urali.conf
unset PASS

cat > /etc/systemd/system/postgrest-urali.service <<UNIT
[Unit]
Description=PostgREST API for urali
After=postgresql.service
Requires=postgresql.service

[Service]
User=postgrest
ExecStart=/usr/local/bin/postgrest /etc/postgrest/urali.conf
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable postgrest-urali >/dev/null 2>&1
systemctl restart postgrest-urali
sleep 3
systemctl is-active postgrest-urali

log "5/7 Adding /api to the urali Nginx site (with rate limit)"
cat > /etc/nginx/conf.d/urali-ratelimit.conf <<'NGX'
limit_req_zone $binary_remote_addr zone=urali_rpc:10m rate=20r/m;
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

    # Reservations: POST only, rate limited
    location /api/rest/v1/rpc/ {
        limit_except POST { deny all; }
        limit_req zone=urali_rpc burst=10 nodelay;
        limit_req_status 429;
        client_max_body_size 16k;
        proxy_pass http://127.0.0.1:${API_PORT}/rpc/;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    # Batch counts and products: read only
    location /api/rest/v1/ {
        limit_except GET { deny all; }
        proxy_pass http://127.0.0.1:${API_PORT}/;
        proxy_set_header Host \$host;
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
if nginx -t; then
  systemctl reload nginx
else
  echo "Nginx test failed, restoring previous config"
  cp "$(ls -t $SITE.bak.* | head -1)" "$SITE"
  nginx -t && systemctl reload nginx
  exit 1
fi

log "6/7 Daily database backup (02:45 IST, kept 14 days)"
mkdir -p /var/backups/urali && chown postgres:postgres /var/backups/urali && chmod 700 /var/backups/urali
cat > /etc/cron.d/urali-backup <<'CRON'
15 21 * * * postgres pg_dump -Fc urali > /var/backups/urali/urali-$(date +\%F).dump && find /var/backups/urali -name '*.dump' -mtime +14 -delete
CRON
chmod 644 /etc/cron.d/urali-backup

log "7/7 Checks"
echo -n "batches via API: "
curl -s -o /dev/null -w '%{http_code}\n' "https://${DOMAIN}/api/rest/v1/batches?select=id,reserved_boxes,status&order=id.asc&limit=3"
curl -s "https://${DOMAIN}/api/rest/v1/batches?select=id,reserved_boxes,status&order=id.asc&limit=3"; echo
echo -n "reservations hidden from public (expect 401/403/404): "
curl -s -o /dev/null -w '%{http_code}\n' "https://${DOMAIN}/api/rest/v1/reservations?select=phone"
echo -n "direct write blocked (expect 403): "
curl -s -o /dev/null -w '%{http_code}\n' -X POST "https://${DOMAIN}/api/rest/v1/batches" -H 'Content-Type: application/json' -d '{}'
runuser -u postgres -- psql -d "$DB" -qtAc "select jobname, schedule from cron.job order by jobname"
rm -rf "$TMP"
echo; echo "Done. API: https://${DOMAIN}/api"
