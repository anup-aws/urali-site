#!/usr/bin/env bash
# Applies migration 008: no batches before orders_open_from (set to 2026-11-04).
#
#   curl -fsSL -o /tmp/u8.sh https://raw.githubusercontent.com/anup-aws/urali-site/main/update-urali-008.sh && bash /tmp/u8.sh
#
# To move the date later afterwards, no redeploy needed:
#   runuser -u postgres -- psql -d urali -c "update public.settings set value='\"2026-12-02\"' where key='orders_open_from'; select public.ensure_batches();"
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/anup-aws/urali-site/main"
DB=urali
DOMAIN=uralichips.com

log()   { printf '\n==> %s\n' "$*"; }
psqlq() { runuser -u postgres -- psql -X -q -t -A -d "$DB" -c "$1"; }
psqlt() { runuser -u postgres -- psql -X -q -d "$DB" -c "$1"; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }
TMP=$(mktemp -d); chmod 755 "$TMP"; trap 'rm -rf "$TMP"' EXIT

log "1/5 Safety backup"
mkdir -p /var/backups/urali
BK="/var/backups/urali/urali-pre-008-$(date +%F-%H%M).dump"
runuser -u postgres -- pg_dump -Fc "$DB" > "$BK"
chown postgres:postgres "$BK"; chmod 600 "$BK"
echo "  wrote $BK ($(du -h "$BK" | cut -f1))"

log "2/5 Calendar before"
psqlt "select id as fry_date, status, reserved_boxes,
              cutoff_at at time zone 'Asia/Kolkata' as cutoff_ist
       from public.batches order by id"

log "3/5 Applying 008_urali_orders_open_from.sql"
curl -fsSL "$REPO_RAW/008_urali_orders_open_from.sql?r=$RANDOM" -o "$TMP/008.sql"
chmod 644 "$TMP/008.sql"
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$TMP/008.sql"

log "4/5 Calendar after"
psqlt "select id as fry_date, status, reserved_boxes,
              cutoff_at at time zone 'Asia/Kolkata' as cutoff_ist
       from public.batches order by id"
echo -n "  orders_open_from: "; psqlq "select public.setting_date('orders_open_from')"
echo -n "  next batch the site will show: "
psqlq "select id from public.batches
       where status in ('open','confirmed','full') and cutoff_at > now()
       order by id limit 1"

log "5/5 Proving maintenance does not recreate the early batches"
psqlq "select public.run_maintenance()" >/dev/null
psqlq "select public.run_maintenance()" >/dev/null
echo -n "  offered batches before orders_open_from (must be 0): "
psqlq "select count(*) from public.batches
       where id < public.setting_date('orders_open_from')
         and status in ('open','confirmed','full')"
echo -n "  offered batches total (expect 6): "
psqlq "select count(*) from public.batches where status in ('open','confirmed','full')"

log "What the live site returns"
curl -s "https://$DOMAIN/api/rest/v1/batches?select=id,cutoff_at,reserved_boxes,status&status=in.(open,confirmed,full)&order=id.asc&limit=1"
echo

echo
echo "Done. Rollback if needed:"
echo "  runuser -u postgres -- pg_restore -c -d $DB $BK"
