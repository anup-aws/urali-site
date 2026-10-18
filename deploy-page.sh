#!/usr/bin/env bash
# Deploys index.html only. No database, no nginx, no services touched.
# Keeps a timestamped backup and rolls back by itself if the live page breaks.
#
#   curl -fsSL -o /tmp/dp.sh https://raw.githubusercontent.com/anup-aws/urali-site/main/deploy-page.sh && bash /tmp/dp.sh
#
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/anup-aws/urali-site/main"
LIVE=/var/www/urali/index.html
DOMAIN=uralichips.com

log() { printf '\n==> %s\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }
TMP=$(mktemp -d); chmod 755 "$TMP"; trap 'rm -rf "$TMP"' EXIT

log "1/5 Fetching the new page"
curl -fsSL "$REPO_RAW/index.html?r=$RANDOM" -o "$TMP/index.html"
echo "  $(wc -c <"$TMP/index.html") bytes"

log "2/5 Sanity checks before anything is replaced"
fail=0
for marker in "loadMedia" "batchesShown: 1" "North Bengaluru" "560077" "560043" "560016" \
              "pin-list" "datestrip" "cutoffText" "create_reservation"; do
  if grep -q "$marker" "$TMP/index.html"; then
    printf '  ok      %s\n' "$marker"
  else
    printf '  MISSING %s\n' "$marker"; fail=1
  fi
done
# the four area names must still match what the database accepts
for a in Kothanur Horamavu "Ramamurthy Nagar" Byrathi; do
  grep -q "$a" "$TMP/index.html" || { printf '  MISSING area %s\n' "$a"; fail=1; }
done
[ "$fail" -eq 0 ] || { echo; echo "Refusing to deploy: the downloaded page is missing something."; exit 1; }

log "3/5 Backing up the page that is live now"
BK="/var/www/urali/index-$(date +%F-%H%M).html.bak"
cp -p "$LIVE" "$BK"
echo "  $BK"
# keep the five most recent backups
ls -1t /var/www/urali/index-*.html.bak 2>/dev/null | tail -n +6 | xargs -r rm -f

log "4/5 Installing"
install -m 644 "$TMP/index.html" "$LIVE"
echo "  installed"

log "5/5 Checking the live site"
code=$(curl -s -o "$TMP/live.html" -w '%{http_code}' "https://$DOMAIN/?cb=$RANDOM")
echo "  GET https://$DOMAIN/  ->  $code"
ok=1
[ "$code" = "200" ] || ok=0
grep -q "North Bengaluru" "$TMP/live.html" || ok=0
grep -q "560077" "$TMP/live.html" || ok=0
if [ "$ok" -eq 1 ]; then
  echo "  live page is serving the new content"
else
  echo "  LIVE CHECK FAILED - rolling back"
  cp -p "$BK" "$LIVE"
  curl -s -o /dev/null -w '  after rollback: %{http_code}\n' "https://$DOMAIN/"
  exit 1
fi

echo
echo "Done. To roll back by hand:"
echo "  cp $BK $LIVE"
