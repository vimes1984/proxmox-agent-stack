#!/usr/bin/env bash
# install/40-paperclip.sh — runs INSIDE CT_PAPERCLIP (Debian 13).
#
# Paperclip: agent-company control plane (board, agents, tasks) on :3100.
#
# This is the flow that was actually proven end to end on CT 231 — a faithful
# replay of the community-scripts paperclip installer, hardened and made
# idempotent. The parts that matter and are easy to get wrong:
#
#   * pnpm is pinned to the repo's own packageManager (pnpm@9.15.4) via corepack.
#     A newer global pnpm fights the lockfile.
#   * install runs with HUSKY=0 and NODE_OPTIONS=--max-old-space-size=8192,
#     otherwise the monorepo build OOMs in an 8 GB container.
#   * the .env needs the PAPERCLIP_* block (home, config, instance id, deployment
#     mode/exposure, public URL) + BETTER_AUTH_SECRET, not just DATABASE_URL.
#     Without them `onboard` writes its config somewhere the service never reads.
#   * first-run bootstrap is `pnpm paperclipai onboard --yes --bind lan`
#     (falling back to no --bind on older tags). Do not invent --email/--password
#     flags; they do not exist.
#   * the admin invite is minted by `pnpm paperclipai auth bootstrap-ceo` and
#     written to /root/paperclip.creds (mode 600), never to the log.
#   * the service runs `pnpm paperclipai run`, not `pnpm start`.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH="/root/.cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mok\033[0m  %s\n' "$*"; }
warn() { printf '    \033[1;33mwarn\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mFATAL\033[0m %s\n' "$*" >&2; exit 1; }

SRC=/opt/paperclip-ai
PAPERCLIP_HOME=/opt/paperclip-data
PAPERCLIP_CONFIG="$PAPERCLIP_HOME/instances/default/config.json"
LOCAL_IP="$(hostname -I | awk '{print $1}')"

echo "=== Paperclip install — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo "memory: $(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo) MB   cores: $(nproc)   ip: ${LOCAL_IP}"

step "1. system packages"
apt-get update -qq
apt-get install -y -qq build-essential git ripgrep curl ca-certificates openssl python3 gnupg >/dev/null
ok "build-essential / git / ripgrep / curl / openssl / python3"

step "2. Node 24 + pnpm"
if ! command -v node >/dev/null 2>&1 || [ "$(node -v | sed 's/v\([0-9]*\).*/\1/')" -lt 20 ]; then
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash - >/dev/null 2>&1
  apt-get install -y -qq nodejs >/dev/null
fi
corepack enable >/dev/null 2>&1 || true
corepack prepare pnpm@9.15.4 --activate >/dev/null 2>&1 || npm install -g pnpm@9.15.4 >/dev/null 2>&1
ok "node $(node -v)  npm $(npm -v)  pnpm $(pnpm -v)"

step "3. PostgreSQL 17 + paperclip database"
if ! command -v psql >/dev/null 2>&1 || ! psql --version | grep -q ' 17'; then
  install -d /usr/share/postgresql-common/pgdg
  curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    https://www.postgresql.org/media/keys/ACCC4CF8.asc
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(. /etc/os-release; echo "$VERSION_CODENAME")-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list
  apt-get update -qq
  apt-get install -y -qq postgresql-17 >/dev/null || die "postgresql-17 install failed"
fi
systemctl enable --now postgresql >/dev/null 2>&1; sleep 4

# password kept off the command line and out of the log
PGPASS_FILE=/opt/paperclip.pgpass
if [ -f "$PGPASS_FILE" ]; then PGPASS="$(cat "$PGPASS_FILE")"; else
  PGPASS="$(openssl rand -hex 16)"; printf '%s' "$PGPASS" > "$PGPASS_FILE"; chmod 600 "$PGPASS_FILE"
fi
su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='paperclip'\"" 2>/dev/null | grep -q 1 \
  || su - postgres -c "psql -qc \"CREATE USER paperclip\"" >/dev/null 2>&1
su - postgres -c "psql -qc \"ALTER USER paperclip PASSWORD '$PGPASS'\"" >/dev/null 2>&1
su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='paperclip'\"" 2>/dev/null | grep -q 1 \
  || su - postgres -c "createdb -O paperclip paperclip" >/dev/null 2>&1
ok "$(psql --version) — db paperclip / user paperclip"

step "4. Rust toolchain (Paperclip's native pieces)"
if ! command -v cargo >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y >/dev/null 2>&1
fi
export PATH="/root/.cargo/bin:$PATH"
command -v cargo >/dev/null || warn "cargo still missing — the build may fail on native deps"
ok "rust $(rustc --version 2>/dev/null | awk '{print $2}')  cargo $(cargo --version 2>/dev/null | awk '{print $2}')"

step "5. Paperclip source (latest release tag)"
if [ -d "$SRC" ] && [ -f "$SRC/package.json" ]; then
  ok "source already present — keeping it ($(du -sh "$SRC" | cut -f1))"
else
  TAG="$(curl -fsSL https://api.github.com/repos/paperclipai/paperclip/releases/latest 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null)"
  echo "    latest release: ${TAG:-<none — will clone default branch>}"
  rm -rf "$SRC"
  if [ -n "${TAG:-}" ] && curl -fsSL --max-time 300 -o /tmp/pc.tar.gz \
       "https://github.com/paperclipai/paperclip/archive/refs/tags/${TAG}.tar.gz" 2>/dev/null && [ -s /tmp/pc.tar.gz ]; then
    mkdir -p "$SRC" && tar -xzf /tmp/pc.tar.gz -C "$SRC" --strip-components=1
    ok "tarball ${TAG} extracted ($(du -sh "$SRC" | cut -f1))"
  else
    git clone --depth 1 https://github.com/paperclipai/paperclip.git "$SRC" 2>&1 | tail -3
    ok "git clone ($(du -sh "$SRC" | cut -f1))"
  fi
fi
python3 - "$SRC/package.json" <<'PY' 2>/dev/null || true
import json,sys
d=json.load(open(sys.argv[1]))
print("    name:", d.get("name"), "| version:", d.get("version"), "| packageManager:", d.get("packageManager"))
PY

step "6. pnpm install + build (long: 15–30 min in 8 GB)"
cd "$SRC" || die "$SRC missing"
export HUSKY=0
export NODE_OPTIONS="--max-old-space-size=8192"
if [ -d node_modules ] && [ -d "$(find . -maxdepth 4 -type d -name dist 2>/dev/null | head -1)" ] \
   && [ -n "$(find . -maxdepth 4 -type d -name dist 2>/dev/null | head -1)" ]; then
  ok "build output already present — skipping (delete node_modules + dist to force a rebuild)"
else
  pnpm install --frozen-lockfile 2>&1 | tail -20
  [ "${PIPESTATUS[0]}" = 0 ] || die "pnpm install failed — see the tail above (~/paperclip-install.log)"
  pnpm build 2>&1 | tail -35
  [ "${PIPESTATUS[0]}" = 0 ] || die "pnpm build failed — see the tail above (~/paperclip-install.log)"
  ok "build complete"
fi
unset NODE_OPTIONS
echo "    memory available after build: $(free -m | awk '/Mem:/ {print $7}') MB"

step "7. agent CLIs the board's agents run on"
if ! command -v claude >/dev/null 2>&1 || ! command -v codex >/dev/null 2>&1; then
  npm install -g @anthropic-ai/claude-code@latest @openai/codex@latest 2>&1 | tail -5
fi
ok "claude $(claude --version 2>&1 | head -1)   codex $(codex --version 2>&1 | head -1)"

step "8. .env + runtime home"
mkdir -p "$PAPERCLIP_HOME" /root/.claude /root/.codex
if [ -f "$SRC/.env" ] && grep -q '^BETTER_AUTH_SECRET=' "$SRC/.env" 2>/dev/null; then
  ok ".env already present — keeping it"
  set -a; . "$SRC/.env"; set +a
else
  BETTER_AUTH_SECRET="$(openssl rand -hex 32)"
  cat > "$SRC/.env" <<ENVEOF
DATABASE_URL=postgresql://paperclip:${PGPASS}@127.0.0.1:5432/paperclip
HOST=0.0.0.0
PORT=3100
SERVE_UI=true
PAPERCLIP_HOME=${PAPERCLIP_HOME}
PAPERCLIP_CONFIG=${PAPERCLIP_CONFIG}
PAPERCLIP_INSTANCE_ID=default
PAPERCLIP_DEPLOYMENT_MODE=authenticated
PAPERCLIP_DEPLOYMENT_EXPOSURE=private
PAPERCLIP_PUBLIC_URL=http://${LOCAL_IP}:3100
BETTER_AUTH_SECRET=${BETTER_AUTH_SECRET}
ENVEOF
  chmod 600 "$SRC/.env"
  set -a; . "$SRC/.env"; set +a
  ok ".env written ($(grep -c . "$SRC/.env") keys, mode 600)"
fi

step "9. database migrations"
pnpm db:migrate 2>&1 | tail -15
ok "db:migrate exit ${PIPESTATUS[0]}"

step "10. onboard (--bind lan, with the older-tag fallback)"
if [ -f "$PAPERCLIP_CONFIG" ]; then
  ok "config already exists: $PAPERCLIP_CONFIG"
else
  for CMD in "pnpm paperclipai onboard --yes --bind lan" "pnpm paperclipai onboard --yes"; do
    rm -f "$SRC/paperclip-onboard.log"
    setsid bash -c "cd $SRC && exec $CMD" >"$SRC/paperclip-onboard.log" 2>&1 &
    PID=$!
    for _ in $(seq 1 60); do [ -f "$PAPERCLIP_CONFIG" ] && break; kill -0 "$PID" 2>/dev/null || break; sleep 2; done
    kill -0 "$PID" 2>/dev/null && { kill -- -"$PID" >/dev/null 2>&1; wait "$PID" 2>/dev/null; }
    [ -f "$PAPERCLIP_CONFIG" ] && break
    grep -q "unknown option '--bind'" "$SRC/paperclip-onboard.log" || break
  done
  if [ -f "$PAPERCLIP_CONFIG" ]; then ok "config created: $PAPERCLIP_CONFIG"
  else warn "bootstrap did not create a config:"; tail -15 "$SRC/paperclip-onboard.log"; fi
fi

step "11. CEO invite (authenticated mode)"
if [ -f "$PAPERCLIP_CONFIG" ] && grep -q authenticated "$PAPERCLIP_CONFIG" 2>/dev/null; then
  pnpm paperclipai auth bootstrap-ceo >"$SRC/paperclip-bootstrap.log" 2>&1 || true
  INVITE="$(awk -F'Invite URL: ' '/Invite URL:/ {print $2; exit}' "$SRC/paperclip-bootstrap.log")"
  EXP="$(awk -F'Expires: ' '/Expires:/ {print $2; exit}' "$SRC/paperclip-bootstrap.log")"
  if [ -n "${INVITE:-}" ]; then
    printf 'Paperclip Admin Invite\nInvite URL: %s\nExpires: %s\n' "$INVITE" "${EXP:-unknown}" > /root/paperclip.creds
    chmod 600 /root/paperclip.creds
    ok "invite written to /root/paperclip.creds (expires ${EXP:-unknown}) — deliberately not printed"
  else
    warn "no invite generated; last lines of the bootstrap log:"; tail -8 "$SRC/paperclip-bootstrap.log"
  fi
else
  ok "local trusted mode (no invite needed) — you land straight in the board"
fi

step "12. systemd unit"
cat > /etc/systemd/system/paperclip.service <<'UNITEOF'
[Unit]
Description=Paperclip
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/paperclip-ai
EnvironmentFile=/opt/paperclip-ai/.env
Environment=HOME=/root
Environment=CODEX_HOME=/root/.codex
Environment=PATH=/root/.local/bin:/usr/local/bin:/usr/bin:/bin
Environment=DISABLE_AUTOUPDATER=1
ExecStart=/usr/bin/env pnpm paperclipai run
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/paperclip.log
StandardError=append:/var/log/paperclip.log

[Install]
WantedBy=multi-user.target
UNITEOF
systemctl daemon-reload
systemctl enable --now paperclip >/dev/null 2>&1
sleep 20
ok "paperclip: active=$(systemctl is-active paperclip) enabled=$(systemctl is-enabled paperclip 2>/dev/null)"

step "13. verification"
ss -ltn | grep -E ':3100|:5432' | sed 's/^/    /' || warn "nothing listening on 3100/5432"
code="$(curl -s -o /dev/null -w '%{http_code}' -m 20 http://127.0.0.1:3100/ || true)"
echo "    GET http://127.0.0.1:3100/ -> HTTP ${code}"
[ "$code" = "200" ] || [ "$code" = "302" ] || [ "$code" = "307" ] \
  || warn "board not answering yet — journalctl -u paperclip -n 40 --no-pager"

echo
echo "Paperclip is up:  http://${LOCAL_IP}:3100/"
if [ -f /root/paperclip.creds ]; then
  echo "First login:       pct exec ${CT_PAPERCLIP:?set CT_PAPERCLIP} -- cat /root/paperclip.creds   (invite URL, 1 hour)"
else
  echo "First login:       http://${LOCAL_IP}:3100/  (local trusted mode — no invite)"
fi
echo "Logs:              pct exec ${CT_PAPERCLIP:?set CT_PAPERCLIP} -- journalctl -u paperclip -n 50 --no-pager"
