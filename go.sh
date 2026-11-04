#!/usr/bin/env bash
# go.sh — one command driver, run this on the Proxmox VE node as root.
#
#   ./go.sh create      create + start the four containers
#   ./go.sh twenty      build Twenty CRM        (CT_TWENTY)
#   ./go.sh semantica   install Semantica       (CT_SEMANTICA)
#   ./go.sh paperclip   build Paperclip         (CT_PAPERCLIP)
#   ./go.sh hermes      install Hermes Agent    (CT_HERMES)
#   ./go.sh verify      prove all four answer
#   ./go.sh urls        print the addresses
#   ./go.sh all         everything, in dependency order
#   ./go.sh logs <name> tail the build log inside that container
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mok\033[0m  %s\n' "$*"; }
warn() { printf '    \033[1;33mwarn\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mFATAL\033[0m %s\n' "$*" >&2; exit 1; }

[ -f .env ] || { warn "no .env — copying .env.example (edit it if your ids/storage differ)"; cp .env.example .env; }
set -a; . ./.env; set +a

command -v pct >/dev/null || die "pct not found — this must run on the Proxmox VE node, as root."
[ "$(id -u)" = 0 ] || die "run as root."

ct_of() {
  case "$1" in
    twenty) echo "$CT_TWENTY" ;;
    semantica) echo "$CT_SEMANTICA" ;;
    paperclip) echo "$CT_PAPERCLIP" ;;
    hermes) echo "$CT_HERMES" ;;
    *) die "unknown component: $1 (twenty|semantica|paperclip|hermes)" ;;
  esac
}

ct_ip() {
  local id="$1" ip=""
  for _ in $(seq 1 60); do
    ip="$(pct exec "$id" -- hostname -I 2>/dev/null | awk '{print $1}')"
    [ -n "$ip" ] && { echo "$ip"; return 0; }
    sleep 3
  done
  return 1
}

require_ct() {
  local id="$1" name="$2"
  pct status "$id" >/dev/null 2>&1 || die "container $id ($name) does not exist — run ./go.sh create first"
  [ "$(pct status "$id" | awk '{print $2}')" = running ] || { step "starting CT $id"; pct start "$id"; sleep 5; }
}

# push the in-container script + any support files, then run it with logging
run_in_ct() {
  local comp="$1" id script
  id="$(ct_of "$comp")"
  script="$(ls install/*-"$comp".sh 2>/dev/null | head -1)"
  [ -n "$script" ] || die "no install/*-${comp}.sh found next to go.sh"
  require_ct "$id" "$comp"

  step "$comp — installing inside CT $id (log: /root/${comp}-install.log)"
  pct push "$id" "$script" "/root/${comp}-install.sh" --perms 755
  # support files, if the component has any
  for f in "files/${comp}-"*.js; do
    [ -e "$f" ] || continue
    pct push "$id" "$f" "/root/$(basename "$f")" --perms 644
  done
  # env values the in-container script may want
  pct exec "$id" -- env \
      MODEL_PROVIDER="$MODEL_PROVIDER" MODEL_DEFAULT="$MODEL_DEFAULT" \
      CT_TWENTY="$CT_TWENTY" CT_SEMANTICA="$CT_SEMANTICA" \
      CT_PAPERCLIP="$CT_PAPERCLIP" CT_HERMES="$CT_HERMES" \
      DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}" \
      TS_AUTHKEY="${TS_AUTHKEY:-}" TS_HOSTNAME="${TS_HOSTNAME:-agent-stack-hermes}" \
      bash -c "bash /root/${comp}-install.sh 2>&1 | tee /root/${comp}-install.log; exit \${PIPESTATUS[0]}"

  local ip; ip="$(ct_ip "$id" || true)"
  ok "$comp finished — CT $id at ${ip:-<no ip yet>}"
}

urls() {
  printf '\n%-12s %-6s %s\n' COMPONENT CT URL
  for c in twenty semantica paperclip hermes; do
    local id ip; id="$(ct_of "$c")"; ip="$(ct_ip "$id" 2>/dev/null || echo '<not running>')"
    case "$c" in
      twenty)    printf '%-12s %-6s http://%s/\n'        "$c" "$id" "$ip" ;;
      semantica) printf '%-12s %-6s http://%s:8000/docs\n' "$c" "$id" "$ip" ;;
      paperclip) printf '%-12s %-6s http://%s:3100/\n'   "$c" "$id" "$ip" ;;
      hermes)    printf '%-12s %-6s http://%s:9119/\n'   "$c" "$id" "$ip" ;;
    esac
  done
  echo
}

case "${1:-}" in
  create)
    bash proxmox/10-create-cts.sh
    urls
    ;;
  twenty|semantica|paperclip|hermes)
    run_in_ct "$1"
    ;;
  verify)
    bash verify/verify-all.sh
    ;;
  urls)
    urls
    ;;
  logs)
    c="${2:-}"; [ -n "$c" ] || die "usage: ./go.sh logs <twenty|semantica|paperclip|hermes>"
    pct exec "$(ct_of "$c")" -- tail -n 60 "/root/${c}-install.log"
    ;;
  all)
    bash proxmox/10-create-cts.sh
    urls
    run_in_ct twenty
    run_in_ct semantica
    run_in_ct paperclip
    run_in_ct hermes
    bash verify/verify-all.sh || warn "verify reported failures — see above, and ./go.sh logs <name>"
    urls
    ;;
  *)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
