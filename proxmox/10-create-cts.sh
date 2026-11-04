#!/usr/bin/env bash
# proxmox/10-create-cts.sh — create (or reuse) the four Debian 13 containers.
# Runs on the Proxmox VE node as root. Idempotent: existing CTs are left alone.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; . "$HERE/.env"; set +a

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mok\033[0m  %s\n' "$*"; }
warn() { printf '    \033[1;33mwarn\033[0m %s\n' "$*"; }

# --- 1. template -------------------------------------------------------------
step "Debian 13 template"
tpl="$(pveam list "$CT_TEMPLATE_STORAGE" 2>/dev/null | awk '/debian-13-standard/ {print $1}' | tail -1)"
if [ -z "$tpl" ]; then
  warn "no debian-13 template in $CT_TEMPLATE_STORAGE — updating catalogue (this may take a minute)"
  pveam update >/dev/null 2>&1
  name="$(pveam available --section system 2>/dev/null | awk '/debian-13-standard/ {print $2}' | tail -1)"
  [ -n "$name" ] || { echo "could not find a debian-13-standard template upstream"; exit 1; }
  pveam download "$CT_TEMPLATE_STORAGE" "$name" >/dev/null 2>&1
  tpl="$CT_TEMPLATE_STORAGE:vztmpl/$name"
fi
ok "$tpl"

# --- 2. containers -----------------------------------------------------------
create_ct() {
  local id="$1" host="$2" mem="$3" cores="$4" disk="$5" static_ip="$6" desc="$7"
  if pct status "$id" >/dev/null 2>&1; then
    ok "CT $id ($host) already exists — left as is"
    return 0
  fi
  local net="name=eth0,bridge=$CT_BRIDGE,ip=dhcp"
  [ -n "$static_ip" ] && net="name=eth0,bridge=$CT_BRIDGE,ip=$static_ip${GATEWAY:+,gw=$GATEWAY}"

  pct create "$id" "$tpl" \
    --hostname "$host" \
    --memory "$mem" --cores "$cores" --swap 512 \
    --rootfs "$CT_ROOTFS_STORAGE:$disk" \
    --net0 "$net" \
    --nameserver "${DNS:-1.1.1.1}" \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 \
    --description "$desc" >/dev/null 2>&1 || { echo "pct create $id failed"; return 1; }
  pct start "$id" >/dev/null 2>&1
  ok "CT $id ($host) created and started — ${mem} MB / ${cores} cores / ${disk} GB"
}

step "containers"
create_ct "$CT_TWENTY"    twenty    "$TWENTY_MEM"    "$TWENTY_CORES"    "$TWENTY_DISK"    "${STATIC_IP_TWENTY:-}"    "Twenty CRM — self-hosted, source build"
create_ct "$CT_SEMANTICA" semantica "$SEMANTICA_MEM" "$SEMANTICA_CORES" "$SEMANTICA_DISK" "${STATIC_IP_SEMANTICA:-}" "Semantica — knowledge graph + provenance"
create_ct "$CT_PAPERCLIP" paperclip "$PAPERCLIP_MEM" "$PAPERCLIP_CORES" "$PAPERCLIP_DISK" "${STATIC_IP_PAPERCLIP:-}" "Paperclip — agent company control plane"
create_ct "$CT_HERMES"    hermes    "$HERMES_MEM"    "$HERMES_CORES"    "$HERMES_DISK"    "${STATIC_IP_HERMES:-}"    "Hermes Agent"

# --- 3. wait for network -----------------------------------------------------
step "waiting for containers to get an address"
for id in "$CT_TWENTY" "$CT_SEMANTICA" "$CT_PAPERCLIP" "$CT_HERMES"; do
  ip=""
  for _ in $(seq 1 40); do
    ip="$(pct exec "$id" -- hostname -I 2>/dev/null | awk '{print $1}')"
    [ -n "$ip" ] && break
    sleep 3
  done
  [ -n "$ip" ] && ok "CT $id -> $ip" || warn "CT $id has no address yet (check bridge/DHCP)"
done

# --- 4. base packages --------------------------------------------------------
step "base packages in each container"
for id in "$CT_TWENTY" "$CT_SEMANTICA" "$CT_PAPERCLIP" "$CT_HERMES"; do
  pct exec "$id" -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq curl ca-certificates git gnupg lsb-release >/dev/null 2>&1' \
    && ok "CT $id base packages" || warn "CT $id base package install had errors (non-fatal, retried per component)"
done

echo
echo "Containers ready. Next:  ./go.sh twenty   (then semantica, paperclip, hermes)"
