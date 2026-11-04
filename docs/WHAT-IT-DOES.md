# What this actually does (plain English)

This repo installs **four separate small servers onto one Proxmox machine**, then leaves
them running as normal Linux services. That's the whole trick — there is no Docker, no
Kubernetes, no cloud account, and nothing to pay for beyond the hardware.

Think of it as four Raspberry-Pi-ish boxes that happen to be containers on your Proxmox
host, each doing exactly one job:

| # | What you call it | What it is, in normal words | Where you open it |
|---|---|---|---|
| 1 | **Twenty** | A self-hosted CRM. Contacts, companies, deals. It's the open-source alternative to Salesforce/HubSpot — your data stays on your box. | `http://<host-ip>:80` |
| 2 | **Semantica** | A memory/knowledge service. It stores facts as a graph (things + links between them) and keeps a record of where each fact came from, so an AI agent can look things up and show its working. | `http://<ip>:8000/docs` |
| 3 | **Paperclip** | A board for AI agents. You list agents and tasks, and it can hand work out to them. It also installs the `claude` and `codex` command-line agents so those "workers" exist. | `http://<ip>:3100` |
| 4 | **Hermes** | An AI agent that you talk to. It has a web dashboard, can run tools, and can be pointed at your own model key. | `http://<ip>:9119` |

They are deliberately **independent**. Each lives in its own container with its own
database, so you can break, rebuild or skip one without touching the others. You do not
need all four. If you only want the CRM, install only the CRM.

---

## What the installer literally does

`go.sh` is a thin wrapper. It does not contain any clever magic — it copies a script into
a container and runs it there as root. Every install script is plain bash plus `apt-get`,
so you can read it and see exactly what will happen before you run it.

### Step 0 — `./go.sh create`
Downloads the Debian 13 LXC template if it isn't already there, then creates four
containers with fixed IDs and fixed resources:

| Container | ID | RAM | Cores | Disk |
|---|---|---|---|---|
| Twenty | 120 | 8 GB | 4 | 40 GB |
| Semantica | 121 | 4 GB | 2 | 20 GB |
| Paperclip | 122 | 8 GB | 4 | 40 GB |
| Hermes | 123 | 4 GB | 2 | 20 GB |

Each gets an IP by DHCP on your normal bridge (`vmbr0`), `nesting=1`, and `onboot=1`
so it comes back after a host reboot. If a container already exists it is left alone —
this step is safe to re-run.

### `./go.sh twenty` — the long one (40–60 min)
Installs PostgreSQL 17 + pgvector + Redis, installs Node 24, downloads the latest
Twenty source release, runs `yarn install` and a full `nx` production build, creates the
`twenty` database user and `twenty_db`, writes `/opt/twenty/.env`, initialises the
schema, and starts three services: `twenty-server` (the API, port 3000),
`twenty-worker` (background jobs) and `twenty-web` (the front door on port 80).

**Why there's a port 80 service:** the Twenty build produces an API and a pile of static
front-end files, but the API doesn't serve those files. `files/twenty-web-server.js` is
about 100 lines of plain Node that serves the front end and forwards `/graphql`, `/api`,
`/files` and friends to the API. That's the difference between "blank white page" and a
working CRM — it replaces nginx.

### `./go.sh semantica` — quick (about 5 min)
Installs Python 3, creates a venv at `/opt/semantica/venv`, installs
`semantica[parse-pdf,llm-deepseek]`, creates the data directory and a SQLite provenance
database at `/opt/semantica/data/provenance.db`, then runs the service under systemd as a
FastAPI app on port 8000. Browsing to `/docs` gives you a clickable API explorer — that's
the fastest way to confirm it's genuinely alive.

### `./go.sh paperclip` — the second-longest (30–45 min)
The fussiest of the four, because it has native dependencies. Installs Node 24, pins
`pnpm` to 9.15.4 (a newer pnpm fights the project's lockfile), installs PostgreSQL 17,
generates a database password and writes it to `/opt/paperclip.pgpass` (mode 600),
installs Rust, downloads the latest Paperclip release, runs `pnpm install` and
`pnpm build` with the heap cap raised so an 8 GB container doesn't get killed
mid-build, installs the `claude` and `codex` CLIs, writes a `.env`, runs the database
migrations, and boots it on port 3100.

Then it creates your admin account and writes a **one-hour login invite link** to
`/root/paperclip.creds` (mode 600). If you miss that hour, re-mint it — details in
`docs/GOTCHAS.md`.

### `./go.sh hermes` — quick (about 3 min)
Runs the official Hermes installer, symlinks the binary into `/usr/local/bin`, saves your
model provider + key if you put one in `.env`, and starts `hermes-web` on port 9119.
Tailscale is optional and skipped unless you paste an auth key into `.env`.

### `./go.sh verify`
This is the only step that tells you the truth. For each service it checks four things:
the container is running, the systemd unit is active, something is actually listening on
the port, and an HTTP request returns a sane status code. PASS/FAIL per line, non-zero
exit if anything failed. Do not consider the job done until this is all green.

---

## What you end up with

Four URLs on your LAN, four passwords/secrets kept in files on the box, and four
services that survive reboots. That's it.

## What it deliberately does NOT do

Be clear-eyed about the gaps — none of these are bugs, they're just not in scope:

- **No TLS and no domain names.** Everything is plain HTTP on your LAN. Putting a domain
  and certificates in front is a later, separate job (Caddy or Cloudflare Tunnel).
- **No backups.** Nothing here snapshots the databases. `vzdump` on the Proxmox host, or
  `pg_dump` on a cron, is on you.
- **No hardening.** Services bind to `0.0.0.0` because that's what makes them reachable
  from your laptop. Don't expose these ports to the internet as-is.
- **No mail, no SSO.** Paperclip does email-based login invites; if outbound mail isn't
  configured those invites won't leave the box — copy the link out of
  `/root/paperclip.creds` instead.
- **Not version-pinned by us.** It fetches the latest upstream release of Twenty and
  Paperclip. If upstream ships something broken, an install today can fail where one
  last month worked. That's the trade for not maintaining forks.
- **Never run end-to-end on a *fresh* Proxmox node.** Each stage was built and proven on
  a real node, but a virgin-box run is still the honest test. Expect one or two paper cuts
  on the first attempt and read `docs/GOTCHAS.md` before you start debugging.

## Before you start — the two things that will waste your afternoon

1. **Use `tmux`.** `./go.sh twenty` runs for the better part of an hour. If your SSH
   session drops, the build dies with it. `tmux new -s stack` first, then work inside it.
2. **Give the build room.** `local-lvm` needs roughly 130 GB free, and Twenty needs its
   full 8 GB. Undersized RAM shows up as a build that gets killed with no obvious error.
