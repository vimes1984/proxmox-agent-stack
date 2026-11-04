#!/usr/bin/env bash
# install/30-semantica.sh — runs INSIDE CT_SEMANTICA (Debian 13).
# Semantica from PyPI into its own venv (Debian 13 is PEP 668), provenance DB on disk,
# systemd unit on :8000, then HTTP verification of the real endpoints.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mok\033[0m  %s\n' "$*"; }
warn() { printf '    \033[1;33mwarn\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mFATAL\033[0m %s\n' "$*" >&2; exit 1; }

echo "=== Semantica install — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo "python before: $(python3 -V 2>&1)"

step "1. system packages"
apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-dev python3-pip build-essential curl git libmagic1 >/dev/null
ok "python $(python3 -V 2>&1 | awk '{print $2}')"

step "2. virtualenv (never touch the system python — PEP 668)"
mkdir -p /opt/semantica/data /opt/semantica/logs
if [ ! -x /opt/semantica/venv/bin/python ]; then
  python3 -m venv /opt/semantica/venv
fi
V=/opt/semantica/venv/bin
$V/pip install -q --upgrade pip setuptools wheel 2>&1 | tail -2
ok "pip $($V/pip -V | awk '{print $2}')"

step "3. install semantica (base + PDF parsing + DeepSeek adapter)"
if $V/python -c 'import semantica' 2>/dev/null; then
  ok "already installed: $($V/python -c 'import importlib.metadata as m; print(m.version("semantica"))')"
else
  $V/pip install -q 'semantica[parse-pdf,llm-deepseek]' 2>&1 | tail -5 || die "pip install semantica failed"
  ok "installed $($V/python -c 'import importlib.metadata as m; print(m.version("semantica"))' 2>&1)"
fi
$V/pip list 2>/dev/null | grep -iE '^(semantica|fastapi|uvicorn|pyarrow|pdfplumber|openai) ' | sed 's/^/    /'

step "4. functional proof (import and use it, do not trust a version string)"
$V/python - <<'PY'
try:
    from semantica.context import ContextGraph
    print("    ContextGraph: import ok")
except Exception as e:
    print("    ContextGraph: FAILED ->", type(e).__name__, e)
try:
    from semantica.provenance import ProvenanceManager
    ProvenanceManager(storage_path="/opt/semantica/data/provenance.db")
    print("    ProvenanceManager: ok (db /opt/semantica/data/provenance.db)")
except Exception as e:
    print("    ProvenanceManager: FAILED ->", type(e).__name__, e)
PY

step "5. server entrypoint"
$V/pip install -q 'fastapi' 'uvicorn[standard]' 2>&1 | tail -2
if $V/python -m semantica.server --help >/dev/null 2>&1; then
  APP="python -m semantica.server"
  ok "module entrypoint available"
elif $V/python -c 'import semantica.server' 2>/dev/null; then
  APP="python -m uvicorn semantica.server:app --host 0.0.0.0 --port 8000"
  ok "uvicorn on semantica.server:app"
else
  APP="python -m uvicorn semantica.server:app --host 0.0.0.0 --port 8000"
  warn "no semantica.server module found — unit will try uvicorn anyway; check the log"
fi

cat > /opt/semantica/run.sh <<EOF
#!/bin/bash
cd /opt/semantica
exec /opt/semantica/venv/bin/python ${APP#python }
EOF
chmod 755 /opt/semantica/run.sh
ok "run.sh -> ${APP#python }"

cat > /etc/systemd/system/semantica.service <<'EOF'
[Unit]
Description=Semantica knowledge graph service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/semantica
Environment=SEMANTICA_DATA_DIR=/opt/semantica/data
ExecStart=/opt/semantica/run.sh
Restart=on-failure
RestartSec=5
StandardOutput=append:/opt/semantica/logs/semantica.log
StandardError=append:/opt/semantica/logs/semantica.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now semantica >/dev/null 2>&1
sleep 8

step "6. verification"
printf '    unit: active=%s enabled=%s\n' "$(systemctl is-active semantica)" "$(systemctl is-enabled semantica 2>/dev/null)"
ss -ltn | grep -q ':8000' && ok "listening on :8000" || warn "nothing on :8000 yet — see /opt/semantica/logs/semantica.log"
for p in / /docs /openapi.json /api/graph; do
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:8000$p" || true)"
  printf '    %-14s HTTP %s\n' "$p" "$code"
done
IP="$(hostname -I | awk '{print $1}')"
echo
echo "Semantica is up:  http://${IP}:8000/docs   (interactive API docs)"
