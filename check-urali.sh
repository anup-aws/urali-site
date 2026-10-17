#!/usr/bin/env bash
# Read-only health report for urali. Changes nothing — no writes, no restarts, no migrations.
#
# Safe to paste the output into chat: customer names, phone numbers, addresses and
# notes are never printed. Only codes, box counts, areas and statuses are shown.
#
#   curl -fsSL https://raw.githubusercontent.com/anup-aws/urali-site/main/check-urali.sh | bash
#
set -uo pipefail
DB=urali
DOMAIN=uralichips.com

[ "$(id -u)" -eq 0 ] || { echo "Run this as root:  sudo -i  then paste the curl line again."; exit 1; }

hdr() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
q()   { runuser -u postgres -- psql -X -q -t -A -d "$DB" -c "$1" 2>&1; }
qt()  { runuser -u postgres -- psql -X -q -d "$DB" -c "$1" 2>&1; }

hdr "1. Services"
for s in postgresql nginx postgrest-urali postgrest-urali-admin urali-media; do
  if systemctl list-unit-files "$s.service" >/dev/null 2>&1 && \
     systemctl cat "$s.service" >/dev/null 2>&1; then
    printf '  %-26s %s\n' "$s" "$(systemctl is-active "$s" 2>&1)"
  else
    printf '  %-26s NOT INSTALLED\n' "$s"
  fi
done

hdr "2. Maintenance timer"
if systemctl cat urali-maintenance.timer >/dev/null 2>&1; then
  systemctl is-active urali-maintenance.timer | sed 's/^/  active: /'
  systemctl list-timers urali-maintenance.timer --no-pager 2>/dev/null | sed -n '2p' | sed 's/^/  /'
  echo "  last run:"
  systemctl show urali-maintenance.service -p ExecMainStatus -p ExecMainExitTimestamp 2>/dev/null | sed 's/^/    /'
else
  echo "  NOT INSTALLED  <- rollover would not be running"
fi

hdr "3. Listening ports (expect 3100 public API, 3101 admin, 3102 studio)"
ss -ltnp 2>/dev/null | grep -E '127\.0\.0\.1:(3100|3101|3102|5432)' | awk '{print "  "$4"  "$6}' || echo "  none found"

hdr "4. Which migrations are applied"
for o in \
  "function:create_reservation_core" \
  "function:create_reservation" \
  "function:log_event" \
  "function:req_ip" \
  "function:next_open_batch" \
  "function:rollover_unfilled_batches" \
  "function:move_reservation" \
  "function:run_maintenance" \
  "function:admin_action" \
  "view:admin_batches" \
  "view:admin_orders" \
  "view:admin_kitchen" \
  "view:admin_delivery" \
  "view:admin_funnel_daily" \
; do
  kind=${o%%:*}; name=${o#*:}
  if [ "$kind" = function ]; then
    r=$(q "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='$name'")
  else
    r=$(q "select count(*) from pg_views where schemaname='public' and viewname='$name'")
  fi
  [ "${r:-0}" -gt 0 ] 2>/dev/null && printf '  %-34s yes\n' "$name" || printf '  %-34s MISSING\n' "$name"
done

hdr "5. Batch state"
qt "select id as fry_date, status, reserved_boxes, paid_boxes, target_boxes, capacity_boxes,
           cutoff_at at time zone 'Asia/Kolkata' as cutoff_ist
    from public.batches order by id" | sed 's/^/  /'

hdr "6. Reservations by batch and status (no personal data)"
qt "select batch_id, status, count(*) as rows, sum(boxes) as boxes
    from public.reservations group by 1,2 order by 1,2" | sed 's/^/  /'

hdr "7. The stuck 2026-10-14 batch: why did rollover not move these?"
qt "select r.code, r.boxes, r.area, r.status,
           r.created_at at time zone 'Asia/Kolkata' as created_ist,
           public.next_open_batch(r.batch_id, r.boxes) as would_move_to
    from public.reservations r
    where r.batch_id = '2026-10-14'
    order by r.created_at" | sed 's/^/  /'
echo "  (would_move_to empty => no open batch had room for that many boxes)"

hdr "8. Web root and 006 media"
ls -la /var/www/urali 2>/dev/null | awk 'NR>1{printf "  %-10s %-22s %s\n",$5,$6" "$7" "$8,$9}' || echo "  /var/www/urali missing"
echo "  images dir:"
ls -la /var/www/urali/images 2>/dev/null | awk 'NR>1{printf "    %-10s %s\n",$5,$9}' || echo "    no images/ dir  <- 006 not applied"
echo "  manifest:"
if [ -f /var/www/urali/images/manifest.json ]; then
  echo "    present, $(wc -c </var/www/urali/images/manifest.json) bytes"
  grep -o '"[a-z-]*":' /var/www/urali/images/manifest.json 2>/dev/null | tr -d '":' | sort -u | sed 's/^/      slot: /'
else
  echo "    ABSENT  <- site is still showing the drawn hero, not photos"
fi
echo "  originals:"
ls /var/www/urali/images/originals 2>/dev/null | sed 's/^/    /' || echo "    none"

hdr "9. Nginx"
nginx -t 2>&1 | sed 's/^/  /'
echo "  marker blocks in the urali site file:"
grep -nE '# [<>]{3} urali' /etc/nginx/sites-available/urali 2>/dev/null | sed 's/^/    /' || echo "    none found"

hdr "10. TLS certificates"
for d in "$DOMAIN" urali.anups.cloud; do
  c=/etc/letsencrypt/live/$d/fullchain.pem
  if [ -f "$c" ]; then
    printf '  %-22s expires %s\n' "$d" "$(openssl x509 -enddate -noout -in "$c" | cut -d= -f2)"
  else
    printf '  %-22s no certificate\n' "$d"
  fi
done

hdr "11. Backups"
ls -la /var/backups/urali 2>/dev/null | awk 'NR>1 && $9!="." && $9!=".."{printf "  %-12s %s %s %s\n",$5,$6,$7,$9}' | tail -5 || echo "  none"
echo "  cron entry:"
cat /etc/cron.d/urali-backup 2>/dev/null | grep -v '^#' | sed 's/^/    /' || echo "    MISSING"

hdr "12. Public API reachability from the server itself"
for p in "batches?limit=1" "products?limit=1"; do
  printf '  GET /api/rest/v1/%-16s %s\n' "$p" \
    "$(curl -s -o /dev/null -w '%{http_code}' "https://$DOMAIN/api/rest/v1/$p")"
done
printf '  %-28s %s  (expect 401 or 404)\n' "reservations leak check" \
  "$(curl -s -o /dev/null -w '%{http_code}' "https://$DOMAIN/api/rest/v1/reservations?select=phone")"
printf '  %-28s %s  (expect 401)\n' "admin requires auth" \
  "$(curl -s -o /dev/null -w '%{http_code}' "https://$DOMAIN/admin/")"
printf '  %-28s %s  (expect 401)\n' "studio requires auth" \
  "$(curl -s -o /dev/null -w '%{http_code}' "https://$DOMAIN/studio/")"
printf '  %-28s %s  (200 = 006 live, 404 = not applied)\n' "images/manifest.json" \
  "$(curl -s -o /dev/null -w '%{http_code}' "https://$DOMAIN/images/manifest.json")"
printf '  %-28s %s  (200 = 006 live)\n' "images/og-image.jpg" \
  "$(curl -s -o /dev/null -w '%{http_code}' "https://$DOMAIN/images/og-image.jpg")"

echo
echo "Done. Nothing was changed."
