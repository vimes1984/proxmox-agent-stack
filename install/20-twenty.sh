#!/usr/bin/env bash
# install/20-twenty.sh — runs INSIDE CT_TWENTY (Debian 13).
# Twenty CRM from source: PostgreSQL 17 + pgvector, Redis, Node 24, yarn/nx builds,
# systemd units for server + worker, plus a small front door that serves the SPA and
# proxies the API on port 80.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mok\033[0m  %s\n' "$*"; }
warn() { printf '    \033[1;33mwarn\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mFATAL\033[0m %s\n' "$*" >&2; exit 1; }

echo "=== Twenty CRM install — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
MEM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
echo "memory: ${MEM_MB} MB   cores: $(nproc)"
[ "$MEM_MB" -ge 7000 ] || warn "Twenty's nx build wants ~8 GB; ${MEM_MB} MB may OOM. Continuing anyway."

# ---------------------------------------------------------------- 1. packages
step "1. system packages"
apt-get update -qq
apt-get install -y -qq build-essential curl ca-certificates openssl git python3 gnupg lsb-release redis-server >/dev/null
ok "base packages"

# ------------------------------------------------------------- 2. postgres 17
step "2. PostgreSQL 17 + pgvector"
if ! command -v psql >/dev/null 2>&1 || ! psql --version | grep -q ' 17'; then
  install -d /usr/share/postgresql-common/pgdg
  curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    https://www.postgresql.org/media/keys/ACCC4CF8.asc
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(. /etc/os-release; echo $VERSION_CODENAME)-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list
  apt-get update -qq
  apt-get install -y -qq postgresql-17 postgresql-17-pgvector >/dev/null || die "postgresql-17 install failed"
fi
systemctl enable --now postgresql >/dev/null 2>&1; sleep 3
ok "$(psql --version)"

PGPASS_FILE=/opt/twenty.pgpass
if [ -f "$PGPASS_FILE" ]; then
  PGPASS="$(cat "$PGPASS_FILE")"
else
  PGPASS="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
  mkdir -p /opt && printf '%s' "$PGPASS" > "$PGPASS_FILE" && chmod 600 "$PGPASS_FILE"
fi
su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='twenty'\"" | grep -q 1 \
  || su - postgres -c "psql -qc \"CREATE USER twenty PASSWORD '$PGPASS'\""
su - postgres -c "psql -qc \"ALTER USER twenty PASSWORD '$PGPASS'\"" >/dev/null 2>&1
su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='twenty_db'\"" | grep -q 1 \
  || su - postgres -c "createdb -O twenty twenty_db"
su - postgres -c "psql -qc 'GRANT ALL ON SCHEMA public TO twenty' twenty_db" >/dev/null 2>&1
su - postgres -c "psql -qc 'CREATE EXTENSION IF NOT EXISTS vector' twenty_db" >/dev/null 2>&1
ok "db twenty_db / user twenty / pgvector"

# ------------------------------------------------------------------- 3. node
step "3. Node 24 + yarn 4.9.2"
if ! command -v node >/dev/null 2>&1 || [ "$(node -v | sed 's/v\([0-9]*\).*/\1/')" -lt 22 ]; then
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash - >/dev/null 2>&1
  apt-get install -y -qq nodejs >/dev/null
fi
ok "node $(node -v) / npm $(npm -v)"
corepack enable >/dev/null 2>&1 || true
corepack prepare yarn@4.9.2 --activate >/dev/null 2>&1 || npm install -g yarn@4.9.2 >/dev/null 2>&1
ok "yarn $(yarn --version 2>/dev/null || echo '?')"

# ----------------------------------------------------------------- 4. source
step "4. Twenty source (latest release)"
TAG="$(curl -fsSL https://api.github.com/repos/twentyhq/twenty/releases/latest | python3 -c 'import json,sys;print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null)"
[ -n "$TAG" ] || { warn "could not resolve latest tag — using main"; TAG="main"; }
ok "target: $TAG"

if [ -d /opt/twenty/packages/twenty-server ]; then
  ok "source already present at /opt/twenty (skipping download)"
else
  rm -rf /opt/twenty
  if curl -fsSL --max-time 600 -o /tmp/twenty.tar.gz \
      "https://github.com/twentyhq/twenty/archive/refs/tags/${TAG}.tar.gz" && [ -s /tmp/twenty.tar.gz ]; then
    mkdir -p /opt/twenty && tar -xzf /tmp/twenty.tar.gz -C /opt/twenty --strip-components=1
    ok "tarball unpacked ($(du -sh /opt/twenty | cut -f1))"
  else
    warn "tarball failed — falling back to git clone"
    git clone --depth 1 --branch "$TAG" https://github.com/twentyhq/twenty.git /opt/twenty 2>&1 | tail -3
  fi
fi
cd /opt/twenty || die "/opt/twenty missing"

# ------------------------------------------------------------------ 5. build
step "5. yarn install (this is the slow part)"
export NODE_OPTIONS="--max-old-space-size=4096"
export CI=1
yarn install --immutable 2>&1 | tail -5 || { warn "immutable install failed — retrying plain yarn install"; yarn install 2>&1 | tail -5; }
ok "dependencies installed"

step "6. build server + front"
npx nx run twenty-server:build 2>&1 | tail -8 || die "twenty-server build failed"
ok "server built"
npx nx build twenty-front 2>&1 | tail -8 || die "twenty-front build failed"
ok "front built"
cp -r /opt/twenty/packages/twenty-front/build /opt/twenty/packages/twenty-server/dist/front 2>/dev/null || true

# -------------------------------------------------------------------- 6. env
step "7. environment + migrations"
LOCAL_IP="$(hostname -I | awk '{print $1}')"
APP_SECRET="$(openssl rand -base64 32)"
cat > /opt/twenty/.env <<EOF
NODE_PORT=3000
NODE_ENV=production
PG_DATABASE_URL=postgresql://twenty:${PGPASS}@localhost:5432/twenty_db
REDIS_URL=redis://localhost:6379
SERVER_URL=http://${LOCAL_IP}
FRONTEND_URL=http://${LOCAL_IP}
APP_SECRET=${APP_SECRET}
STORAGE_TYPE=local
STORAGE_LOCAL_PATH=/opt/twenty/.local-storage
EOF
chmod 600 /opt/twenty/.env
mkdir -p /opt/twenty/.local-storage
ok "wrote /opt/twenty/.env (SERVER_URL=http://${LOCAL_IP})"

cd /opt/twenty/packages/twenty-server
yarn database:init:prod 2>&1 | tail -6 || warn "database:init:prod reported errors — check the log before trusting the app"
ok "schema initialised"

# ---------------------------------------------------------------- 7. units
step "8. systemd units"
cat > /etc/systemd/system/twenty-server.service <<'EOF'
[Unit]
Description=Twenty CRM server
After=network.target postgresql.service redis-server.service
Requires=postgresql.service redis-server.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/twenty/packages/twenty-server
EnvironmentFile=/opt/twenty/.env
ExecStart=/usr/bin/node dist/main
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/twenty-server.log
StandardError=append:/var/log/twenty-server.log

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/twenty-worker.service <<'EOF'
[Unit]
Description=Twenty CRM worker
After=network.target postgresql.service redis-server.service twenty-server.service
Requires=postgresql.service redis-server.service twenty-server.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/twenty/packages/twenty-server
EnvironmentFile=/opt/twenty/.env
Environment=DISABLE_DB_MIGRATIONS=true
Environment=DISABLE_CRON_JOBS_REGISTRATION=true
ExecStart=/usr/bin/node dist/queue-worker/queue-worker
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/twenty-worker.log
StandardError=append:/var/log/twenty-worker.log

[Install]
WantedBy=multi-user.target
EOF

# front door: serve the built SPA on :80 and proxy API prefixes to :3000
if [ -f /root/twenty-web-server.js ]; then
  mkdir -p /opt/twenty-web
  install -m 644 /root/twenty-web-server.js /opt/twenty-web/server.js
  cat > /etc/systemd/system/twenty-web.service <<'EOF'
[Unit]
Description=Twenty CRM web front door (SPA + API proxy)
After=network.target twenty-server.service
Requires=twenty-server.service

[Service]
Type=simple
User=root
Environment=WEB_ROOT=/opt/twenty/packages/twenty-front/build
Environment=API_HOST=127.0.0.1
Environment=API_PORT=3000
Environment=PORTS=80
ExecStart=/usr/bin/node /opt/twenty-web/server.js
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/twenty-web.log
StandardError=append:/var/log/twenty-web.log

[Install]
WantedBy=multi-user.target
EOF
  ok "front door unit written (:80 -> SPA + /graphql,/api -> :3000)"
else
  warn "twenty-web-server.js not found in /root — the SPA will not be served on :80"
fi

systemctl daemon-reload
systemctl enable --now redis-server >/dev/null 2>&1
systemctl enable --now twenty-server >/dev/null 2>&1
systemctl enable --now twenty-worker >/dev/null 2>&1
[ -f /etc/systemd/system/twenty-web.service ] && systemctl enable --now twenty-web >/dev/null 2>&1

step "9. verification (30s for first boot)"
sleep 30
for u in redis-server postgresql twenty-server twenty-worker; do
  printf '    %-16s active=%-8s enabled=%s\n' "$u" "$(systemctl is-active $u)" "$(systemctl is-enabled $u 2>/dev/null)"
done
ss -ltn | grep -cE ':3000|:5432|:6379' | xargs -I{} echo "    listeners on 3000/5432/6379: {}"
code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/ || true)"
echo "    API  http://127.0.0.1:3000/  -> HTTP $code"
fcode="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/ || true)"
echo "    SPA  http://127.0.0.1/       -> HTTP $fcode"
echo
echo "Twenty is up:  http://${LOCAL_IP}/   (open it and create your workspace + admin user)"
echo "API endpoint:  http://${LOCAL_IP}:3000/graphql"
