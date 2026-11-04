#!/usr/bin/env bash
# install/50-hermes.sh — runs INSIDE CT_HERMES (Debian 13).
# Hermes Agent: official installer, model provider configured, optional Tailscale.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mok\033[0m  %s\n' "$*"; }
warn() { printf '    \033[1;33mwarn\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mFATAL\033[0m %s\n' "$*" >&2; exit 1; }

echo "=== Hermes Agent install — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

step "1. dependencies"
apt-get update -qq
apt-get install -y -qq curl ca-certificates git python3 python3-venv python3-pip build-essential jq sqlite3 >/dev/null
ok "base packages"

step "2. Hermes Agent (official installer)"
if command -v hermes >/dev/null 2>&1; then
  ok "hermes already installed: $(hermes --version 2>/dev/null | head -1)"
else
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash 2>&1 | tail -12 || die "hermes installer failed"
fi

# the installer drops the binary in ~/.local/bin or ~/.hermes/bin — make it findable
for p in /root/.local/bin/hermes /root/.hermes/bin/hermes "$HOME/.local/bin/hermes"; do
  [ -x "$p" ] && ln -sf "$p" /usr/local/bin/hermes && ok "symlinked $p -> /usr/local/bin/hermes" && break
done
export PATH="/usr/local/bin:$PATH"
command -v hermes >/dev/null || die "hermes binary not found after install"

step "3. model provider"
if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
  hermes config set providers.deepseek.api_key "$DEEPSEEK_API_KEY" >/dev/null 2>&1 \
    && ok "deepseek key set" || warn "could not set the deepseek key — run: hermes config set providers.deepseek.api_key <KEY>"
  hermes config set model.provider "${MODEL_PROVIDER:-deepseek}" >/dev/null 2>&1 || true
  hermes config set model.default "${MODEL_DEFAULT:-deepseek-chat}" >/dev/null 2>&1 || true
  ok "model: ${MODEL_PROVIDER:-deepseek}/${MODEL_DEFAULT:-deepseek-chat}"
else
  warn "no DEEPSEEK_API_KEY in .env — add one later with: hermes config set providers.deepseek.api_key <KEY>"
fi

step "4. dashboard on :9119"
mkdir -p /root/.hermes
# bind the web dashboard so it is reachable on the LAN
hermes config set webui.host 0.0.0.0  >/dev/null 2>&1 || true
hermes config set webui.port 9119     >/dev/null 2>&1 || true

cat > /etc/systemd/system/hermes-web.service <<'EOF'
[Unit]
Description=Hermes Agent web dashboard
After=network.target

[Service]
Type=simple
User=root
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=HOME=/root
WorkingDirectory=/root
ExecStart=/bin/bash -lc 'exec hermes webui --host 0.0.0.0 --port 9119'
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/hermes-web.log
StandardError=append:/var/log/hermes-web.log

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now hermes-web >/dev/null 2>&1
sleep 10
printf '    hermes-web: active=%s\n' "$(systemctl is-active hermes-web)"
ss -ltn | grep -q ':9119' && ok "listening on :9119" || warn "not on :9119 — /var/log/hermes-web.log; try: hermes webui --host 0.0.0.0 --port 9119"

step "5. optional: Tailscale"
if [ -n "${TS_AUTHKEY:-}" ]; then
  curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1
  tailscale up --authkey "$TS_AUTHKEY" --hostname "${TS_HOSTNAME:-agent-stack-hermes}" --accept-routes >/dev/null 2>&1 \
    && ok "joined tailnet as ${TS_HOSTNAME:-agent-stack-hermes}" || warn "tailscale up failed — check the auth key"
  tailscale ip -4 2>/dev/null | sed 's/^/    tailnet ip: /'
else
  warn "no TS_AUTHKEY — skipping Tailscale (fine for LAN-only)"
fi

IP="$(hostname -I | awk '{print $1}')"
step "6. verification"
echo "    hermes: $(hermes --version 2>/dev/null | head -1)"
hermes config get model.provider 2>/dev/null | sed 's/^/    provider: /'
echo
echo "Hermes is up:  http://${IP}:9119/"
echo "CLI:           pct enter $CT_HERMES  then  hermes"
