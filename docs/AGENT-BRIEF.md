# Agent brief — operating contract for this repo

Point your AI agent here first. This file is written to be *executed*, not admired:
it states what runs where, the exact commands, the definition of done, and the rules that
prevent damage. Human-facing explanation of what the stack is for: `docs/WHAT-IT-DOES.md`.
Symptoms and fixes: `docs/GOTCHAS.md`. Order and dependencies: `docs/BUILD-ORDER.md`.

> **Suggested agent instruction:** "Repository: proxmox-agent-stack. Before doing anything,
> read `docs/AGENT-BRIEF.md` in full and follow it. It is the operating contract."

---

## 1. What runs where

One driver (`go.sh`, bash, ~130 lines) copies a per-service script into a container and
executes it there as root. Nothing else orchestrates. No Docker, no Compose, no k8s, no
Ansible, no Terraform.

| Component | CT | Port | Unit(s) | Installed to | Upstream source |
|---|---|---|---|---|---|
| Twenty CRM | 120 | 80 → 3000 | `twenty-server`, `twenty-worker`, `twenty-web` | `/opt/twenty` | `twentyhq/twenty` (latest release tag) |
| Semantica | 121 | 8000 | `semantica` | `/opt/semantica` | PyPI `semantica[parse-pdf,llm-deepseek]` |
| Paperclip | 122 | 3100 | `paperclip` | `/opt/paperclip/src` | `paperclipai/paperclip` (latest release tag) |
| Hermes Agent | 123 | 9119 | `hermes-web` | `~/.hermes` + `/usr/local/bin/hermes` | `hermes-agent.nousresearch.com/install.sh` |

Container IDs, RAM/cores/disk and storage names are **not hardcoded** — they come from
`.env` (`CT_TWENTY`, `CT_SEMANTICA`, `CT_PAPERCLIP`, `CT_HERMES`, `CT_ROOTFS_STORAGE`,
`CT_BRIDGE`, `DNS`, `MODEL_PROVIDER`, `MODEL_DEFAULT`, …). `.env.example` holds the
defaults; `go.sh` copies it to `.env` on first run.

The four services are **independent** — none needs another to work. Do not introduce
ordering dependencies among Semantica, Paperclip and Hermes. Only `create` must run first.

## 2. Where you are allowed to run things

- `go.sh` runs **on the Proxmox VE node**, as **root**, from the repo root. It hard-exits
  if `pct` is missing or `id -u` is not 0.
- `install/*.sh` run **inside a container**, never on the node. `go.sh` gets them there
  via `pct exec`. Running them on the node installs PostgreSQL and Node system-wide onto
  the hypervisor — the one genuinely destructive mistake available in this repo.
- `proxmox/10-create-cts.sh`, `verify/verify-all.sh` run on the node (verify also curls
  each service from the node after checking from inside).

## 3. Exact commands

```bash
# on the Proxmox node, as root
git clone https://github.com/vimes1984/proxmox-agent-stack.git /root/proxmox-agent-stack
cd /root/proxmox-agent-stack
cp .env.example .env            # edit CT ids / storage / IPs if they collide
tmux new -s stack               # REQUIRED: the installs outlive an SSH session
./go.sh create                  # ~2 min    — four containers, idempotent
./go.sh twenty                  # 40–60 min
./go.sh semantica               # ~5 min
./go.sh paperclip               # 30–45 min
./go.sh hermes                  # ~3 min
./go.sh verify                  # the only trustworthy completion signal
./go.sh urls                    # print all four addresses
```

Other subcommands: `./go.sh all` (everything in order; still only warns if `verify` is
unhappy) and `./go.sh logs <twenty|semantica|paperclip|hermes>` (tail the in-container
log). Each install writes `/root/<component>-install.log` **inside its container** — that
is the file to read when a step dies.

Environment `go.sh` passes into each container: `MODEL_PROVIDER`, `MODEL_DEFAULT`,
`DEEPSEEK_API_KEY`, `TS_AUTHKEY`, `TS_HOSTNAME`, plus the four `CT_*` ids.

## 4. Definition of done

Never report success from an install script's exit code alone. The only proof is:

```bash
./go.sh verify   # PASS/FAIL per service: container running + unit active + port listening + HTTP code
```

Four PASS → done. Anything else → `./go.sh logs <component>`, then `docs/GOTCHAS.md`.
`verify` probes Semantica at `/docs` (not `/health`) deliberately — the install only
guarantees FastAPI serving docs on :8000.

Report the four URLs from `./go.sh urls` when claiming success. An install with no URL is
not a finished job.

## 5. Rules that prevent damage

1. **Never commit `.env`.** It holds the model API key and Tailscale key. `.gitignore`
   covers it — do not remove those lines.
2. **Never print or commit credentials.** Two files matter: `/root/paperclip.creds`
   (admin invite URL, expires in ~1 hour) and `/opt/paperclip.pgpass` (generated DB
   password). Read them, hand them over out of band; do not echo them into logs,
   screenshots, commits or transcripts.
3. **Never edit scripts to inline secrets.** `.env` is the only place values live.
4. **Do not disable a systemd unit to "fix" a port clash.** Find the owner with
   `ss -ltnp` first. Several services bind `0.0.0.0` on purpose.
5. **Do not re-run `./go.sh twenty` casually.** It is idempotent-ish (reuses DB/user,
   reinstalls packages) but re-runs `yarn install` and a full `nx` build — another
   40–60 minutes. To change config: edit `/opt/twenty/.env`, then
   `systemctl restart twenty-server twenty-worker`.
6. **No Docker.** If tempted to "just containerise it", stop — the point is native LXC,
   and every fix in `docs/GOTCHAS.md` assumes native units.
7. **Upstream is unpinned.** The scripts fetch the latest Twenty / Paperclip release. If a
   step that "should" work fails, suspect an upstream change first; the install log
   records which tag was resolved.

## 6. Known sharp edges

| Symptom | Cause | Fix |
|---|---|---|
| Twenty loads blank / `/graphql` 404s | API on :3000 doesn't serve the SPA | `twenty-web` (port 80, `files/twenty-web-server.js`) must be running: `systemctl status twenty-web` |
| Twenty API fine, UI points at wrong host | `SERVER_URL`/`FRONTEND_URL` baked from the container IP at install time | edit `/opt/twenty/.env`, restart `twenty-server` and `twenty-worker` |
| Paperclip build killed, no error | OOM in 8 GB during `pnpm build` | script sets `NODE_OPTIONS=--max-old-space-size=8192`; if it still dies, give the CT 12 GB and re-run `./go.sh paperclip` |
| Paperclip "invite expired" | `bootstrap-ceo` invite lives ~1 hour | `pct exec 122 -- bash -lc 'cd /opt/paperclip/src && pnpm paperclipai auth bootstrap-ceo'`, then read `/root/paperclip.creds` |
| pnpm lockfile / frozen-deps errors | global pnpm too new | `corepack prepare pnpm@9.15.4 --activate` |
| Semantica unit active, `/health` 404 | no `/health` route | use `/docs` or `/openapi.json` |
| `./go.sh` → `FATAL pct not found` | not on the Proxmox node | run on the node as root |
| `./go.sh` → `Permission denied` | executable bit lost (zip download) | `chmod +x go.sh install/*.sh proxmox/*.sh verify/*.sh` |

## 7. Repo map

```
go.sh                      driver: create|twenty|semantica|paperclip|hermes|verify|urls|all|logs
.env.example               all tunables (CT ids, resources, storage, model provider) → copy to .env
proxmox/10-create-cts.sh   template download + idempotent pct create/start per component
install/20-twenty.sh       PostgreSQL 17 + pgvector + Redis + Node 24 + yarn + nx build + 3 units
install/30-semantica.sh    Python venv + semantica[parse-pdf,llm-deepseek] + uvicorn unit
install/40-paperclip.sh    Node 24 + pnpm 9.15.4 + PG 17 + Rust + pnpm build + claude/codex CLIs
install/50-hermes.sh       official installer + model provider + hermes-web unit + optional tailscale
files/twenty-web-server.js stdlib-Node front door for Twenty (static SPA + API proxy on :80)
verify/verify-all.sh       four-signal proof per service (unit / port / in-CT curl / from-node curl)
docs/                      WHAT-IT-DOES.md (why) · BUILD-ORDER.md (order + deps) · GOTCHAS.md (symptoms)
```

## 8. Style for changes here

- Bash, `set -euo pipefail`; reuse the existing `step`/`ok`/`warn`/`die` helpers — this
  output is read by a human watching a long build.
- Every script stays **idempotent**: check before create, keep existing files that hold
  secrets, never clobber a working database.
- Fail loudly and early (`die`) and always leave a log behind.
- `bash -n <script>` before committing; `shellcheck` if available.
- Justify any new dependency. The value of this repo is that it has almost none.
