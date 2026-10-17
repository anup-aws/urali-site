#!/usr/bin/env bash
# Applies migration 007 (rollover fix) and, with RESET=yes, clears all test data.
#
#   Migration only, no data touched:
#     curl -fsSL -o /tmp/u7.sh https://raw.githubusercontent.com/anup-aws/urali-site/main/update-urali-007.sh && bash /tmp/u7.sh
#
#   Migration + wipe every reservation, event and batch, then rebuild batches:
#     RESET=yes bash /tmp/u7.sh
#
# The reset takes its own pg_dump first and prints what it is about to delete.
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/anup-aws/urali-site/main"
DB=urali
RESET="${RESET:-no}"

log()  { printf '\n==> %s\n' "$*"; }
psqlq() { runuser -u postgres -- psql -X -q -t -A -d "$DB" -c "$1"; }
psqlt() { runuser -u postgres -- psql -X -q -d "$DB" -c "$1"; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }

TMP=$(mktemp -d); chmod 755 "$TMP"
trap 'rm -rf "$TMP"' EXIT

log "1/5 Safety backup"
mkdir -p /var/backups/urali
BK="/var/backups/urali/urali-pre-007-$(date +%F-%H%M).dump"
runuser -u postgres -- pg_dump -Fc "$DB" > "$BK"
chown postgres:postgres "$BK"; chmod 600 "$BK"
echo "  wrote $BK ($(du -h "$BK" | cut -f1))"

log "2/5 State before"
psqlt "select status, count(*) as batches, sum(reserved_boxes) as boxes
       from public.batches group by status order by status"
psqlt "select status, count(*) as reservations, sum(boxes) as boxes
       from public.reservations group by status order by status"
echo -n "  events logged: "; psqlq "select count(*) from public.events"

log "3/5 Applying 007_urali_rollover_fix.sql"
curl -fsSL "$REPO_RAW/007_urali_rollover_fix.sql?r=$RANDOM" -o "$TMP/007.sql"
chmod 644 "$TMP/007.sql"
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$TMP/007.sql"
echo "  applied"

if [ "$RESET" = "yes" ]; then
  log "4/5 RESET: clearing all test data"
  echo "  deleting:"
  echo -n "    reservations: "; psqlq "select count(*) from public.reservations"
  echo -n "    events:       "; psqlq "select count(*) from public.events"
  echo -n "    batches:      "; psqlq "select count(*) from public.batches"
  echo -n "    waitlist:     "; psqlq "select count(*) from public.waitlist"
  # reservations reference batches, so order matters. settings and products are kept.
  psqlt "begin;
         delete from public.reservations;
         delete from public.events;
         delete from public.waitlist;
         delete from public.batches;
         commit;"
  echo "  cleared. Rebuilding the batch calendar:"
  echo -n "    batches created: "; psqlq "select public.ensure_batches()"
else
  log "4/5 RESET not requested (RESET=yes to clear test data) — data left untouched"
fi

log "5/6 Admin page and PostgREST schema cache"
# PostgREST caches the schema at start, so a brand-new view is invisible until it
# reloads. Without this, /admin/api/admin_attention would 404.
curl -fsSL "$REPO_RAW/admin.html?r=$RANDOM" -o "$TMP/admin.html"
install -d -m 755 /var/www/urali-admin
install -m 644 "$TMP/admin.html" /var/www/urali-admin/index.html
echo "  admin page updated (Attention tab added)"
systemctl restart postgrest-urali-admin
sleep 2
echo -n "  postgrest-urali-admin: "; systemctl is-active postgrest-urali-admin
echo -n "  admin_attention visible through the admin API: "
curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:3101/admin_attention?limit=1"

log "6/6 State after"
psqlt "select id as fry_date, status, reserved_boxes, target_boxes, capacity_boxes,
              cutoff_at at time zone 'Asia/Kolkata' as cutoff_ist
       from public.batches order by id"
echo -n "  reservations: "; psqlq "select count(*) from public.reservations"
echo -n "  needing attention: "; psqlq "select count(*) from public.admin_attention"
echo -n "  max_rollovers: "; psqlq "select public.setting_int('max_rollovers')"

log "Maintenance dry run (this is what the timer does every 10 minutes)"
psqlt "select public.run_maintenance()"

log "Public API still healthy"
for p in "batches?limit=1" "products?limit=1"; do
  printf '  GET /api/rest/v1/%-18s %s\n' "$p" \
    "$(curl -s -o /dev/null -w '%{http_code}' "https://uralichips.com/api/rest/v1/$p")"
done
printf '  %-30s %s  (expect 401 or 404)\n' "reservations still private" \
  "$(curl -s -o /dev/null -w '%{http_code}' "https://uralichips.com/api/rest/v1/reservations?select=phone")"

echo
echo "Done. Rollback if needed:"
echo "  runuser -u postgres -- pg_restore -c -d $DB $BK"
