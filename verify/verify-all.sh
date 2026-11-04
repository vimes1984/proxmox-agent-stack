#!/usr/bin/env bash
# verify/verify-all.sh — prove the stack answers. Runs on the Proxmox VE node as root.
# Every line is a measurement, not an assertion: unit state, listening socket, HTTP code.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
set -a; . ./.env; set +a

FAIL=0
pass() { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; }
fail() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[1;33mSKIP\033[0m  %s\n' "$*"; }

ct_ip() {
  local id="$1" ip=""
  for _ in $(seq 1 20); do
    ip="$(pct exec "$id" -- hostname -I 2>/dev/null | awk '{print $1}')"
    [ -n "$ip" ] && { echo "$ip"; return 0; }
    sleep 2
  done
  return 1
}

# check_ct <label> <ctid> <unit> <port> <path>
check_ct() {
  local label="$1" id="$2" unit="$3" port="$4" path="$5" ip code state
  printf '\n\033[1m%s (CT %s)\033[0m\n' "$label" "$id"

  if ! pct status "$id" >/dev/null 2>&1; then fail "container $id does not exist — run ./go.sh create"; return; fi
  state="$(pct status "$id" | awk '{print $2}')"
  [ "$state" = running ] && pass "container running" || fail "container is $state (pct start $id)"

  local ustate
  ustate="$(pct exec "$id" -- systemctl is-active "$unit" 2>/dev/null | tr -d '\r')"
  [ "$ustate" = active ] && pass "$unit active" || fail "$unit is '${ustate:-unknown}' (pct exec $id -- journalctl -u $unit -n 30)"

  pct exec "$id" -- ss -ltn 2>/dev/null | grep -q ":${port} " \
    && pass "listening on :$port" || fail "nothing listening on :$port"

  ip="$(ct_ip "$id" || true)"
  if [ -z "$ip" ]; then fail "no IP address inside the container"; return; fi
  pass "ip $ip"

  # from inside the container: proves the service answers its own socket
  code="$(pct exec "$id" -- curl -s -o /dev/null -m 8 -w '%{http_code}' "http://127.0.0.1:${port}${path}" 2>/dev/null | tr -d '\r')"
  case "$code" in
    2??|3??) pass "inside  GET :$port$path -> $code" ;;
    000|"")  fail "inside  GET :$port$path -> no response" ;;
    *)       fail "inside  GET :$port$path -> HTTP $code" ;;
  esac

  # from the Proxmox node: proves the LAN path, not just loopback
  code="$(curl -s -o /dev/null -m 8 -w '%{http_code}' "http://${ip}:${port}${path}" 2>/dev/null)"
  case "$code" in
    2??|3??) pass "from node GET $ip:$port$path -> $code" ;;
    *)       fail "from node GET $ip:$port$path -> HTTP ${code:-none}" ;;
  esac
}

echo "=== stack verification — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

check_ct "Twenty CRM"  "$CT_TWENTY"    twenty-server 80    /
check_ct "Semantica"   "$CT_SEMANTICA" semantica     8000  /docs
check_ct "Paperclip"   "$CT_PAPERCLIP" paperclip     3100  /
check_ct "Hermes"      "$CT_HERMES"    hermes-web    9119  /

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[1;32mALL CHECKS PASSED\033[0m — four services answering on the LAN.\n'
  exit 0
else
  printf '\033[1;31m%d CHECK(S) FAILED\033[0m — fix per the hints above, then re-run ./go.sh verify\n' "$FAIL"
  exit 1
fi
