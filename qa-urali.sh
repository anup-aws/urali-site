#!/usr/bin/env bash
# QA for the urali ordering API. Uses the furthest-out batch (not shown on the page)
# and documentation-only test IPs. Every test reservation is cancelled at the end.
set -uo pipefail
DOMAIN=urali.anups.cloud
API=http://127.0.0.1:3100
PUB=https://$DOMAIN/api/rest/v1
PASS=0; FAIL=0
sql() { runuser -u postgres -- psql -d urali -qtAX -c "$1"; }
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s  (got: %s)\n' "$1" "$2"; }
expect() { # name expected actual
  if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "${3:0:120}"; fi
}

TB=$(sql "select id from batches where status='open' and cutoff_at > now() order by id desc limit 1")
[ -n "$TB" ] || { echo "No open test batch found"; exit 1; }
TARGET=$(sql "select coalesce((select (value#>>'{}')::int from settings where key='target_boxes'),40)")
CAP=$(sql "select coalesce((select (value#>>'{}')::int from settings where key='capacity_boxes'),60)")
echo "  test batch: $TB (hidden from the page)"
REAL=$(sql "select count(*) from reservations where batch_id='$TB' and source<>'qa'")
[ "$REAL" = "0" ] || { echo "Test batch has real orders; stopping QA to protect them."; exit 1; }
R1=$((RANDOM % 150 + 20))
IP_A=192.0.2.$R1; IP_B=192.0.2.$((R1+1)); IP_C=192.0.2.$((R1+2))

# reserve IP PHONE QTY [HP] [MS] [PRODUCT] [AREA]
reserve() {
  local ip=$1 phone=$2 qty=$3 hp=${4:-} ms=${5:-6000} prod=${6:-classic} area=${7:-Horamavu}
  local hpjson=null; [ -n "$hp" ] && hpjson="\"$hp\""
  local out
  out=$(curl -s -w ' HTTP%{http_code}' -X POST "$API/rpc/create_reservation" \
    -H 'Content-Type: application/json' -H "X-Real-IP: $ip" -H 'User-Agent: urali-qa' \
    -d "{\"p_batch\":\"$TB\",\"p_items\":[{\"product_id\":\"$prod\",\"qty\":$qty,\"unit_price\":1}],\"p_name\":\"QA Tester\",\"p_phone\":\"$phone\",\"p_area\":\"$area\",\"p_address\":\"Flat 1, QA road\",\"p_hp\":$hpjson,\"p_elapsed_ms\":$ms,\"p_meta\":{\"device\":\"qa\",\"session_id\":\"qa-session-001\",\"utm\":{\"source\":\"qa\"}}}")
  sql "update reservations set source='qa' where customer_name='QA Tester' and source<>'qa'" >/dev/null
  echo "$out"
}

echo "== Input validation"
expect "honeypot filled is rejected"          "REQUEST_REJECTED"      "$(reserve $IP_A 9000000001 1 bot)"
expect "form sent too fast is rejected"       "TOO_FAST"              "$(reserve $IP_A 9000000001 1 '' 800)"
expect "invalid phone is rejected"            "PHONE_INVALID"         "$(reserve $IP_A 12345 1)"
expect "area outside delivery zone rejected"  "AREA_INVALID"          "$(reserve $IP_A 9000000001 1 '' 6000 classic Indiranagar)"
expect "more than 5 of a box is rejected"     "QTY_INVALID"           "$(reserve $IP_A 9000000001 6)"
expect "coming-soon product can't be ordered" "PRODUCT_UNAVAILABLE"   "$(reserve $IP_A 9000000001 1 '' 6000 tin)"
R=$(reserve $IP_A 9000000001 2)
expect "valid reservation succeeds"           "HTTP200"               "$R"
expect "price comes from server, not browser" '"total": 798'          "$R"

echo "== Spam limits"
reserve $IP_A 9000000001 1 >/dev/null; reserve $IP_A 9000000001 1 >/dev/null
expect "4th active order from one phone blocked" "TOO_MANY_RESERVATIONS" "$(reserve $IP_B 9000000001 1)"
for p in 9000000002 9000000003 9000000004; do reserve $IP_A $p 1 >/dev/null; done
expect "7th order from one IP in an hour blocked" "TOO_MANY_RESERVATIONS" "$(reserve $IP_A 9000000005 1)"
expect "same details from a new IP still work"   "HTTP200"               "$(reserve $IP_C 9000000005 1)"
FLAGS=$(sql "select string_agg(distinct array_to_string(risk_flags,','), ' ') from reservations where source='qa' and ip='$IP_A'")
expect "repeat-IP orders are flagged for review" "ip_repeat" "$FLAGS"
IPSAVED=$(sql "select count(*) from reservations where source='qa' and ip is not null and user_agent='urali-qa'")
expect "IP and device saved on reservations" "yes" "$( [ "$IPSAVED" -gt 0 ] && echo yes || echo no-rows )"

echo "== Capacity and batch rules"
sql "update reservations set status='cancelled' where source='qa' and batch_id='$TB' and status='reserved'; update batches set reserved_boxes=0, status='open', confirmed_at=null, target_boxes=2, capacity_boxes=3 where id='$TB'" >/dev/null
expect "reaching target confirms the batch"  '"now_confirmed": true' "$(reserve 198.51.100.$R1 9000000020 2)"
expect "overbooking is refused with boxes left" "BATCH_FULL:1"       "$(reserve 198.51.100.$((R1+1)) 9000000021 2)"
reserve 198.51.100.$((R1+2)) 9000000022 1 >/dev/null
expect "full batch refuses any more"         "BATCH_FULL:0"          "$(reserve 198.51.100.$((R1+3)) 9000000023 1)"
sql "update reservations set status='cancelled' where source='qa' and batch_id='$TB' and status='reserved'; update batches set reserved_boxes=0, status='open', confirmed_at=null where id='$TB'" >/dev/null
for i in 1 2 3 4 5 6 7 8; do reserve 203.0.113.$((R1+i)) 900000003$i 1 >/dev/null & done; wait
RB=$(sql "select reserved_boxes from batches where id='$TB'")
expect "8 people racing for 3 boxes: never oversold" "3" "$RB"

echo "== Public API surface (through Nginx)"
expect "batch counts are public"            "HTTP200" "$(curl -s -o /dev/null -w 'HTTP%{http_code}' "$PUB/batches?select=id&limit=1")"
expect "reservations table is not reachable" "HTTP404" "$(curl -s -o /dev/null -w 'HTTP%{http_code}' "$PUB/reservations?select=phone")"
expect "admin views are not reachable"       "HTTP404" "$(curl -s -o /dev/null -w 'HTTP%{http_code}' "$PUB/admin_orders")"
expect "internal functions are not reachable" "HTTP404" "$(curl -s -o /dev/null -w 'HTTP%{http_code}' -X POST "$PUB/rpc/ensure_batches" -H 'Content-Type: application/json' -d '{}')"
expect "writing to batches is blocked"       "HTTP403" "$(curl -s -o /dev/null -w 'HTTP%{http_code}' -X POST "$PUB/batches" -H 'Content-Type: application/json' -d '{}')"
expect "analytics event accepted"            "HTTP204" "$(curl -s -o /dev/null -w 'HTTP%{http_code}' -X POST "$PUB/rpc/log_event" -H 'Content-Type: application/json' -d '{"p_session":"qa-session-001","p_event":"qa_check","p_props":{"ok":true},"p_path":"/"}')"
SPOOF=$(curl -s -X POST "$PUB/rpc/create_reservation" -H 'Content-Type: application/json' -H 'X-Real-IP: 1.2.3.4' -H 'X-Forwarded-For: 1.2.3.4' \
  -d "{\"p_batch\":\"$TB\",\"p_items\":[{\"product_id\":\"classic\",\"qty\":1}],\"p_name\":\"QA Tester\",\"p_phone\":\"9000000099\",\"p_area\":\"Byrathi\",\"p_address\":\"Flat 1, QA road\",\"p_elapsed_ms\":6000}")
sql "update reservations set source='qa' where customer_name='QA Tester' and source<>'qa'" >/dev/null
SPOOFIP=$(sql "select host(ip) from reservations where phone='+919000000099' order by created_at desc limit 1")
expect "fake IP headers are ignored" "ok" "$( [ -n "$SPOOFIP" ] && [ "$SPOOFIP" != "1.2.3.4" ] && echo ok || echo "stored=$SPOOFIP" )"
CODES=""
for i in $(seq 1 12); do
  CODES="$CODES $(curl -s -o /dev/null -w '%{http_code}' -X POST "$PUB/rpc/create_reservation" -H 'Content-Type: application/json' \
    -d "{\"p_batch\":\"$TB\",\"p_items\":[{\"product_id\":\"classic\",\"qty\":1}],\"p_name\":\"QA Tester\",\"p_phone\":\"9000000098\",\"p_area\":\"Byrathi\",\"p_address\":\"Flat 1, QA road\",\"p_hp\":\"bot\",\"p_elapsed_ms\":6000}")"
done
expect "rapid-fire requests get rate limited (429)" "429" "$CODES"

echo "== Cleanup"
sql "update reservations set status='cancelled' where source='qa' and status in ('reserved','link_sent'); update batches set reserved_boxes=0, status='open', confirmed_at=null, target_boxes=$TARGET, capacity_boxes=$CAP where id='$TB'" >/dev/null
echo "  test batch $TB restored: $(sql "select reserved_boxes||' boxes, '||status||', target '||target_boxes||', capacity '||capacity_boxes from batches where id='$TB'")"
echo "  real batches: $(sql "select string_agg(id||'='||reserved_boxes, '  ' order by id) from batches where id < '$TB' and status in ('open','confirmed','full')")"

echo; echo "QA result: $PASS passed, $FAIL failed"
exit $FAIL
