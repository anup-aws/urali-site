#!/usr/bin/env bash
# urali update 005: automatic batch rollover, maintenance that does not depend on pg_cron,
# and a password-protected admin page at /admin.
set -euo pipefail
REPO_RAW="https://raw.githubusercontent.com/anup-aws/urali-site/main"
DOMAIN=uralichips.com
ALT=urali.anups.cloud
SITE=/etc/nginx/sites-available/urali
API_PORT=3100
ADMIN_PORT=3101
log() { printf '\n==> %s\n' "$*"; }
fetch() { curl -fsSL "$REPO_RAW/$1?r=$RANDOM" -o "$2"; chmod 644 "$2"; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
TMP=$(mktemp -d); chmod 755 "$TMP"

log "1/7 Applying database update 005"
fetch 005_urali_rollover_admin.sql "$TMP/005.sql"
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q -d urali -f "$TMP/005.sql" >/dev/null
echo "applied"

log "2/7 Admin API (a second PostgREST, localhost only)"
PASS=$(runuser -u postgres -- psql -d urali -qtAX -c "select 1" >/dev/null && openssl rand -hex 24)
printf "alter role urali_admin login password '%s';\ngrant urali_admin to authenticator;\n" "$PASS" \
  | runuser -u postgres -- psql -q -d urali
cat > /etc/postgrest/urali-admin.conf <<CONF
db-uri = "postgres://urali_admin:${PASS}@127.0.0.1:5432/urali"
db-schemas = "public"
db-anon-role = "urali_admin"
server-host = "127.0.0.1"
server-port = ${ADMIN_PORT}
openapi-mode = "disabled"
CONF
chown root:postgrest /etc/postgrest/urali-admin.conf
chmod 640 /etc/postgrest/urali-admin.conf
unset PASS
cat > /etc/systemd/system/postgrest-urali-admin.service <<'UNIT'
[Unit]
Description=PostgREST admin API for urali
After=postgresql.service
Requires=postgresql.service

[Service]
User=postgrest
ExecStart=/usr/local/bin/postgrest /etc/postgrest/urali-admin.conf
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable postgrest-urali-admin >/dev/null 2>&1
systemctl restart postgrest-urali-admin
sleep 3
systemctl is-active postgrest-urali-admin

log "3/7 Maintenance every 10 minutes (no pg_cron needed)"
cat > /usr/local/bin/urali-maintenance <<'SH'
#!/usr/bin/env bash
exec runuser -u postgres -- psql -d urali -qtAX -c "select public.run_maintenance()"
SH
chmod 755 /usr/local/bin/urali-maintenance
cat > /etc/systemd/system/urali-maintenance.service <<'UNIT'
[Unit]
Description=urali batch maintenance
[Service]
Type=oneshot
ExecStart=/usr/local/bin/urali-maintenance
UNIT
cat > /etc/systemd/system/urali-maintenance.timer <<'UNIT'
[Unit]
Description=Run urali batch maintenance every 10 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
Persistent=true
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now urali-maintenance.timer >/dev/null 2>&1
systemctl start urali-maintenance.service
systemctl list-timers urali-maintenance.timer --no-pager | head -3

log "4/7 Admin login"
HT=/etc/nginx/.urali-admin
if [ -f "$HT" ]; then
  echo "Existing login kept at $HT. To change it:  bash $0 --reset-password"
  if [ "${1:-}" = "--reset-password" ]; then rm -f "$HT"; fi
fi
if [ ! -f "$HT" ]; then
  ADMPASS=$(openssl rand -base64 15 | tr -d '/+=' | cut -c1-16)
  printf 'anup:%s\n' "$(openssl passwd -apr1 "$ADMPASS")" > "$HT"
  chown root:www-data "$HT"; chmod 640 "$HT"
  NEWLOGIN=1
fi

log "5/7 Adding /admin to Nginx"
fetch admin.html "$TMP/admin.html"
install -d -m 755 /var/www/urali-admin
install -m 644 "$TMP/admin.html" /var/www/urali-admin/index.html
cp "$SITE" "$SITE.bak.$(date +%s)"
python3 - "$SITE" "$ADMIN_PORT" <<'PY'
import sys, re
path, port = sys.argv[1], sys.argv[2]
s = open(path).read()
# remove any block we added before, so this script can be run again safely
s = re.sub(r'\n?[ \t]*# >>> urali admin.*?# <<< urali admin\n', '\n', s, flags=re.S)
block = """
    # >>> urali admin
    location = /admin { return 301 https://$host/admin/; }

    location /admin/ {
        auth_basic "urali admin";
        auth_basic_user_file /etc/nginx/.urali-admin;
        alias /var/www/urali-admin/;
        index index.html;
    }

    location /admin/api/ {
        auth_basic "urali admin";
        auth_basic_user_file /etc/nginx/.urali-admin;
        client_max_body_size 16k;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Host $host;
        proxy_pass http://127.0.0.1:PORT/;
    }
    # <<< urali admin
""".replace('PORT', port)
anchor = '    location /api/ {\n        return 404;\n    }'
if anchor not in s:
    raise SystemExit('anchor not found in nginx site file')
s = s.replace(anchor, block.strip('\n') + '\n\n' + anchor, 1)
open(path, 'w').write(s)
PY
grep -c "urali admin" "$SITE"
if nginx -t 2>&1 | tail -1; then
  systemctl reload nginx
  sleep 2
else
  echo "Nginx test failed, restoring"; cp "$(ls -t $SITE.bak.* | head -1)" "$SITE"; nginx -t && systemctl reload nginx; exit 1
fi

log "6/7 Updating the landing page (next batch only)"
fetch index.html "$TMP/index.html"
if grep -q "batchesShown: 1" "$TMP/index.html"; then
  install -m 644 "$TMP/index.html" /var/www/urali/index.html
  echo "page updated"
else
  echo "index.html on GitHub is still the older version — upload the new one and re-run."
fi

log "7/7 Checks"
echo -n "admin page without login (expect 401): "
curl -s -o /dev/null -w '%{http_code}\n' "https://$DOMAIN/admin/"
echo -n "admin api without login (expect 401): "
curl -s -o /dev/null -w '%{http_code}\n' "https://$DOMAIN/admin/api/admin_orders"
echo -n "admin views not on the public api (expect 404): "
curl -s -o /dev/null -w '%{http_code}\n' "https://$DOMAIN/api/rest/v1/admin_orders"
echo -n "public batch counts still work (expect 200): "
curl -s -o /dev/null -w '%{http_code}\n' "https://$DOMAIN/api/rest/v1/batches?select=id&limit=1"
echo "batches now:"
runuser -u postgres -- psql -d urali -c "select batch_id, reserved_boxes, target_boxes, status, orders from admin_batches limit 8;"
echo "maintenance timer:"
systemctl is-active urali-maintenance.timer
rm -rf "$TMP"

if [ "${NEWLOGIN:-0}" = "1" ]; then
  printf '\n============================================\n'
  printf '  ADMIN PAGE:  https://%s/admin/\n' "$DOMAIN"
  printf '  Username:    anup\n'
  printf '  Password:    %s\n' "$ADMPASS"
  printf '  Save this now. It is not shown again and it is not stored anywhere readable.\n'
  printf '  Do not paste it into a chat.\n'
  printf '============================================\n\n'
fi
