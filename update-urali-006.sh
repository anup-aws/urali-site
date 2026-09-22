#!/usr/bin/env bash
# urali update 006: image studio for the designer, favicon and WhatsApp link preview.
#   bash update-urali-006.sh                 install or update
#   bash update-urali-006.sh --add-user NAME add another studio login (prints its password once)
set -euo pipefail
REPO_RAW="https://raw.githubusercontent.com/anup-aws/urali-site/main"
DOMAIN=uralichips.com
SITE=/etc/nginx/sites-available/urali
PUBLIC=/var/www/urali/images
PRIVATE=/var/lib/urali-media
STUDIO_HT=/etc/nginx/.urali-studio
ADMIN_HT=/etc/nginx/.urali-admin
PORT=3102
log() { printf '\n==> %s\n' "$*"; }
fetch() { curl -fsSL "$REPO_RAW/$1?r=$RANDOM" -o "$2"; chmod 644 "$2"; }
newpass() { openssl rand -base64 15 | tr -d '/+=' | cut -c1-16; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }

add_user() {
  local name=$1 pw
  [[ "$name" =~ ^[a-z][a-z0-9_-]{1,30}$ ]] || { echo "Use a simple lowercase name, like designer or ravi"; exit 1; }
  touch "$STUDIO_HT"
  sed -i "/^${name}:/d" "$STUDIO_HT"
  pw=$(newpass)
  printf '%s:%s\n' "$name" "$(openssl passwd -apr1 "$pw")" >> "$STUDIO_HT"
  chown root:www-data "$STUDIO_HT"; chmod 640 "$STUDIO_HT"
  printf '\n============================================\n'
  printf '  STUDIO:    https://%s/studio/\n' "$DOMAIN"
  printf '  Username:  %s\n' "$name"
  printf '  Password:  %s\n' "$pw"
  printf '  Shown once. Send it to them privately, not in a group.\n'
  printf '============================================\n'
}

if [ "${1:-}" = "--add-user" ]; then add_user "${2:?give a name, e.g. --add-user designer}"; exit 0; fi

TMP=$(mktemp -d); chmod 755 "$TMP"

log "1/7 Image library (Pillow)"
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq python3-pil >/dev/null
python3 -c "from PIL import features, Image; assert features.check('webp'), 'no webp'; print('Pillow', Image.__version__, 'with WebP')"

log "2/7 Folders and default images"
id urali-media >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin urali-media
install -d -o urali-media -g www-data -m 755 "$PUBLIC"
install -d -o urali-media -g urali-media -m 750 "$PRIVATE" "$PRIVATE/defaults" "$PRIVATE/originals"
for f in favicon.png favicon-180.png favicon-32.png og-image.jpg; do
  fetch "$f" "$TMP/$f"
  install -o urali-media -g urali-media -m 644 "$TMP/$f" "$PRIVATE/defaults/$f"
  [ -f "$PUBLIC/$f" ] || install -o urali-media -g www-data -m 644 "$TMP/$f" "$PUBLIC/$f"
done
# the original drawings, shown first in every version strip; owned by root so the service can't change them
install -d -o root -g www-data -m 755 "$PUBLIC/originals"
for n in hero box-classic box-duo box-tin box-chakka; do
  fetch "original-$n.webp" "$TMP/original-$n.webp"
  install -o root -g www-data -m 644 "$TMP/original-$n.webp" "$PUBLIC/originals/$n.webp"
done
install -o root -g www-data -m 644 "$TMP/favicon.png" "$PUBLIC/originals/favicon.png"
install -o root -g www-data -m 644 "$TMP/og-image.jpg" "$PUBLIC/originals/og-image.jpg"
ls "$PUBLIC" "$PUBLIC/originals"

log "3/7 Media service"
install -d -m 755 /opt/urali-media
fetch media_server.py "$TMP/media_server.py"
python3 -m py_compile "$TMP/media_server.py"
install -m 644 "$TMP/media_server.py" /opt/urali-media/media_server.py
cat > /etc/systemd/system/urali-media.service <<UNIT
[Unit]
Description=urali image studio service
After=network.target

[Service]
User=urali-media
Group=urali-media
UMask=0022
Environment=URALI_MEDIA_PUBLIC=${PUBLIC}
Environment=URALI_MEDIA_PRIVATE=${PRIVATE}
Environment=URALI_MEDIA_PORT=${PORT}
ExecStart=/usr/bin/python3 /opt/urali-media/media_server.py
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${PUBLIC} ${PRIVATE}

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable urali-media >/dev/null 2>&1
systemctl restart urali-media
sleep 2
systemctl is-active urali-media
curl -s "http://127.0.0.1:${PORT}/health"; echo

log "4/7 Studio logins"
NEW_DESIGNER=0
if [ ! -f "$STUDIO_HT" ]; then
  touch "$STUDIO_HT"
  if [ -f "$ADMIN_HT" ] && grep -q '^anup:' "$ADMIN_HT"; then
    grep '^anup:' "$ADMIN_HT" >> "$STUDIO_HT"
    echo "your admin login (anup) also works for the studio"
  fi
  NEW_DESIGNER=1
fi
chown root:www-data "$STUDIO_HT"; chmod 640 "$STUDIO_HT"

log "5/7 Studio page and Nginx"
fetch studio.html "$TMP/studio.html"
install -d -m 755 /var/www/urali-studio
install -m 644 "$TMP/studio.html" /var/www/urali-studio/index.html
if [ -d /var/www/urali-admin ]; then
  fetch admin.html "$TMP/admin.html"
  install -m 644 "$TMP/admin.html" /var/www/urali-admin/index.html
  echo "admin page updated with an Images link"
fi
cp "$SITE" "$SITE.bak.$(date +%s)"
python3 - "$SITE" "$PORT" <<'PY'
import sys, re
path, port = sys.argv[1], sys.argv[2]
s = open(path).read()
s = re.sub(r'\n?[ \t]*# >>> urali studio.*?# <<< urali studio\n', '\n', s, flags=re.S)
# an older admin block used try_files with alias, which Nginx handles badly
s = s.replace("        index index.html;\n        try_files $uri $uri/ /admin/index.html;\n", "        index index.html;\n")
block = """
    # >>> urali studio
    location = /images/manifest.json {
        add_header Cache-Control "no-store" always;
        add_header X-Content-Type-Options "nosniff" always;
    }

    location /images/ {
        add_header Cache-Control "public, max-age=3600" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Content-Security-Policy "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; sandbox" always;
        try_files $uri =404;
    }

    location = /studio { return 301 https://$host/studio/; }

    location /studio/ {
        auth_basic "urali studio";
        auth_basic_user_file /etc/nginx/.urali-studio;
        alias /var/www/urali-studio/;
        index index.html;
    }

    location /studio/api/ {
        auth_basic "urali studio";
        auth_basic_user_file /etc/nginx/.urali-studio;
        client_max_body_size 9m;
        proxy_read_timeout 60s;
        proxy_set_header X-Remote-User $remote_user;
        proxy_set_header Host $host;
        proxy_pass http://127.0.0.1:PORT/;
    }
    # <<< urali studio
""".replace('PORT', port)
anchor = '    location /api/ {\n        return 404;\n    }'
if anchor not in s:
    raise SystemExit('anchor not found in nginx site file')
s = s.replace(anchor, block.strip('\n') + '\n\n' + anchor, 1)
open(path, 'w').write(s)
PY
if nginx -t 2>&1 | tail -1; then
  systemctl reload nginx; sleep 2
else
  echo "Nginx test failed, restoring"; cp "$(ls -t $SITE.bak.* | head -1)" "$SITE"; nginx -t && systemctl reload nginx; exit 1
fi

log "6/7 Landing page"
fetch index.html "$TMP/index.html"
if grep -q "loadMedia" "$TMP/index.html"; then
  install -m 644 "$TMP/index.html" /var/www/urali/index.html
  echo "page updated"
else
  echo "index.html on GitHub is the older version — upload the new one and re-run."
fi

log "7/7 Checks"
chk() { printf '%-52s %s\n' "$1" "$(curl -s -o /dev/null -w '%{http_code}' "$2")"; }
chk "studio without login (expect 401)" "https://$DOMAIN/studio/"
chk "studio api without login (expect 401)" "https://$DOMAIN/studio/api/state"
chk "image list is public (expect 200)" "https://$DOMAIN/images/manifest.json"
chk "link preview image (expect 200)" "https://$DOMAIN/images/og-image.jpg"
chk "favicon (expect 200)" "https://$DOMAIN/images/favicon-32.png"
chk "website (expect 200)" "https://$DOMAIN/"
grep -q 'og:image' /var/www/urali/index.html && echo "link preview tags: present"
rm -rf "$TMP"

if [ "$NEW_DESIGNER" = "1" ]; then add_user designer; fi
