# Proxmox Agent Stack — turnkey seed

One Proxmox node → **four LXC containers**, each running one piece:

| CT | Runs | Port | RAM / disk | Purpose |
|----|------|------|-----------|---------|
| `120` | **Twenty CRM** (self-hosted, built from source) | `80` (app+API), `3000` (API direct) | 8 GB / 40 GB | contacts, companies, pipeline |
| `121` | **Semantica** (knowledge graph + provenance) | `8000` | 4 GB / 20 GB | memory / decision graph, HTTP API + `/docs` |
| `122` | **Paperclip** (agent company control plane) | `3100` | 8 GB / 40 GB | board, agents, tasks |
| `123` | **Hermes Agent** (the agent itself) | `9119` (dashboard) | 4 GB / 20 GB | the thing that does the work |

Everything is installed **natively inside Debian 13 LXCs** — no Docker, no nested
virtualisation, no Kubernetes. That is deliberate: it is the path that has actually
been built and verified end to end on a real Proxmox node.

---

## Prerequisites

* Proxmox VE 8.x node, **root** shell.
* `local-lvm` (or any block storage) with **~130 GB free**, and a `vmbr0` bridge with DHCP.
* A Debian 13 LXC template (`debian-13-standard_*.tar.zst`) — the script downloads it if missing.
* Outbound internet from the containers (they pull from GitHub, npm, PyPI, apt).

Nothing else. No API keys are needed until the very last step (Hermes wants one LLM key).

---

## Quickstart

```bash
# on the Proxmox node, as root
git clone https://github.com/vimes1984/proxmox-agent-stack.git /root/proxmox-agent-stack
cd /root/proxmox-agent-stack
cp .env.example .env          # edit if your storage/bridge/CT IDs differ (defaults are sane)

./go.sh create                # 4 containers, DHCP, started
./go.sh twenty                # ~40–60 min  (the long one)
./go.sh semantica             # ~5 min
./go.sh paperclip             # ~30–45 min
./go.sh hermes                # ~3 min
./go.sh verify                # proves each service answers on its port
```

Or everything in one go (it prints the URL of each piece as it lands):

```bash
./go.sh all
```

Each step is **idempotent** — re-run it and it checks before it acts. Logs land in
`/root/<service>-install.log` inside each container.

When it finishes, `./go.sh urls` prints the four addresses to bookmark.

---

## What you get, exactly

* **Twenty** — built from the latest release tag (`twentyhq/twenty`) with `yarn` + `nx`,
  PostgreSQL 17 + `pgvector`, Redis, `twenty-server` + `twenty-worker` systemd units.
  The built SPA is served by a tiny front-door node server (`files/twenty-web-server.js`)
  that also proxies `/graphql`, `/api`, `/files` to the API — so `http://<ct>:80/` is the
  whole app on one address, which is how Twenty expects to be deployed.
  First visit → create your workspace + admin account.
* **Semantica** — `pip install 'semantica[parse-pdf,llm-deepseek]'` into
  `/opt/semantica/venv`, provenance DB at `/opt/semantica/data/provenance.db`,
  `semantica.service` on `:8000`, verified against `/`, `/docs`, `/openapi.json`, `/api/graph`.
* **Paperclip** — Node 24, pnpm, PostgreSQL 17, Rust toolchain, agent CLIs
  (`claude`, `codex`), `pnpm build`, migrations, onboarding, CEO invite written to
  `/root/paperclip.creds` in the container (never printed to the log), `paperclip.service` on `:3100`.
* **Hermes** — `hermes-agent.nousresearch.com/install.sh`, model provider set via
  `hermes config set`, symlinked into `/usr/local/bin/hermes` so cron and bare SSH shells find it.

---

## Ports and addresses

DHCP by default, so addresses come from your router. `./go.sh urls` reads them live from
`pct config` / `hostname -I`. If you want fixed addresses, set `STATIC_IP` per CT in `.env`
and `./go.sh create` will apply them at creation time.

```
Twenty      http://<ct-120-ip>/            (create admin on first load)
            http://<ct-120-ip>:3000/graphql   (API)
Semantica   http://<ct-121-ip>:8000/docs
Paperclip   http://<ct-122-ip>:3100/
Hermes      http://<ct-123-ip>:9119/
```

---

## Gotchas that will bite you (all learned the hard way)

Read `docs/GOTCHAS.md` before changing anything. The top ones:

1. **Twenty does not serve its own SPA.** The API listens on 3000; the built front end in
   `packages/twenty-front/build` must be served by something. We ship `twenty-web-server.js`
   on `:80` that serves the SPA and proxies the API prefixes. If you only expose 3000 you get
   a white page or an API 404 and think the build failed.
2. **`SERVER_URL` must be the address the browser uses** — not `localhost`. It is written from
   the container's own IP at install time. Move the container to a new subnet and you must
   update `/opt/twenty/.env` and restart `twenty-server`.
3. **Needs 8 GB RAM.** `nx` builds with a 4 GB heap and will OOM-kill on a 4 GB container.
4. **`yarn install --immutable` first, plain `yarn install` as fallback** — the release tarball
   sometimes ships a lockfile that does not match its own `package.json`.
5. **Semantica must go in a venv** — Debian 13 is PEP 668; a system-wide `pip install` fails.
6. **Paperclip needs Rust and an 8 GB node heap** (`NODE_OPTIONS=--max-old-space-size=8192`).
7. **Nothing here is TLS.** These are plain HTTP listeners on your LAN. Put them behind a
   reverse proxy (Caddy/nginx) or a Tailscale/VPN before exposing anything to the internet.

---

## Layout

```
go.sh                     one-command driver (create|twenty|semantica|paperclip|hermes|verify|urls|all)
.env.example              CT ids, storage, bridge, model key
proxmox/10-create-cts.sh  create / start / apply static IPs
install/20-twenty.sh      runs INSIDE CT 120
install/30-semantica.sh   runs INSIDE CT 121
install/40-paperclip.sh   runs INSIDE CT 122
install/50-hermes.sh      runs INSIDE CT 123
files/twenty-web-server.js  SPA + API front door
verify/verify-all.sh      from the PVE host: port/HTTP proof for all four
docs/BUILD-ORDER.md       why this order, dependencies between pieces
docs/GOTCHAS.md           the failure modes, with fixes
```

## Licence

MIT. Upstream pieces keep their own licences: Twenty (AGPL-3.0), Paperclip, Semantica (MIT),
Hermes Agent.
