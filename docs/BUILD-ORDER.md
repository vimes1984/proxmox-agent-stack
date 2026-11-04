# Build order — why it is this order

Run the pieces in the order `go.sh all` uses. Two reasons only: **dependency** and
**RAM**. Everything else can be done in any order.

```
./go.sh create      containers only, no software        ~2 min
./go.sh twenty      longest, most fragile step          ~40-60 min
./go.sh semantica   independent of Twenty                ~5 min
./go.sh paperclip   heaviest build (Rust + node)        ~30-45 min
./go.sh hermes      smallest, needs your LLM key         ~3 min
./go.sh verify      measures all four at once
```

## Dependencies that are real

| Piece | Needs | Why |
|---|---|---|
| Twenty | PostgreSQL 17 + Redis + 8 GB | `nx` build OOMs below 8 GB; the DB is created by its own installer |
| Semantica | Python 3.11+ in a venv | PEP 668 on Debian 13 blocks system-wide pip |
| Paperclip | PostgreSQL 17 + Node 24 + pnpm 9 + Rust + 8 GB | migrations need the DB; native deps need cargo; build needs a big heap |
| Hermes | nothing local | it is a client — it needs an API key, not a database |

**Nothing in the lower three depends on Twenty or on each other.** If you only want the
board, run `create` then `paperclip`. Twenty is a CRM, Semantica is a memory graph,
Paperclip is the board, Hermes is the worker — they talk over HTTP *later*, by
configuration, not at install time.

## Do NOT run two builds at once

The Twenty and Paperclip steps each want ~8 GB of heap plus a Postgres and a Postgres
migration. On a node with 32 GB this looks survivable and then the OOM killer picks one
of them at random. Serial is the safe default. On a 64 GB node you can run `twenty` and
`semantica` in parallel — nothing else.

## After the four are up

The stack is only *plumbed* at this point, not *wired*:

1. Create the Twenty workspace + admin at `http://<ct>:80/`.
2. Create the Paperclip CEO account from the invite in `/root/paperclip.creds`.
3. Point Hermes at the others (its config takes URLs + keys; see the Hermes section).
4. Bring a reverse proxy in front if you want one hostname per service.

Each of those is a *configuration* step, reversible, and none of them can break the
installs above.
