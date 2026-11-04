# Gotchas — the failure modes, with fixes

Every item here is a thing that actually broke during the build on a real node, with the
symptom you will see and the fix. Read this before you change a script.

---

## 1. Twenty serves nothing on `:80` / white page / API 404

**Symptom.** Build finished, `twenty-server` is active, `curl :3000/graphql` answers, but
`http://<ct>/` is blank, 404, or the browser cannot load assets.

**Cause.** Twenty's API and its front end are separate things. The API listens on 3000.
The SPA is a static build in `packages/twenty-front/build` and something has to serve it.

**Fix.** `files/twenty-web-server.js` does exactly that on `:80` and proxies
`/graphql`, `/api`, `/files`, `/oauth` to 3000. If you remove it, you must put nginx/Caddy
in front and replicate the proxy rules.

---

## 2. `SERVER_URL` / `APP_SECRET` wrong after the container moves

**Symptom.** Login redirects to `localhost`, or OAuth/file URLs break, after you change the
container IP or restore it elsewhere.

**Cause.** `SERVER_URL` is baked into `/opt/twenty/.env` at install time from the container's
own IP. The browser must be able to reach the same string.

**Fix.**

```bash
NEW=http://192.168.1.120
sed -i "s|^SERVER_URL=.*|SERVER_URL=$NEW|" /opt/twenty/.env
sed -i "s|^FRONTEND_URL=.*|FRONTEND_URL=$NEW|" /opt/twenty/.env
systemctl restart twenty-server twenty-worker twenty-web
```

---

## 3. Twenty build OOM-killed

**Symptom.** `Killed` at the end of the `nx` build, or exit 137, and the log just stops.

**Cause.** 4 GB container. The build is happy at 8 GB, unhappy below it.

**Fix.** Give the CT 8192 MB (`pct set 120 -memory 8192`) and re-run `./go.sh twenty`.
The script detects a partial build and rebuilds; it does not corrupt anything.

---

## 4. `yarn install --immutable` fails

**Symptom.** Lockfile mismatch error on the release tarball.

**Cause.** Upstream release tarballs sometimes ship a `yarn.lock` that does not match the
`package.json` in the same tarball.

**Fix.** Already handled: the script tries `--immutable`, falls back to a plain
`yarn install`. Do not "fix" the lockfile by hand.

---

## 5. Semantica: `externally-managed-environment` from pip

**Symptom.** `error: externally-managed-environment` when installing semantica.

**Cause.** Debian 13 ships PEP 668. System pip is blocked on purpose.

**Fix.** Already handled: everything goes into `/opt/semantica/venv`, and the systemd unit
runs `/opt/semantica/venv/bin/python`. Never `pip install` semantica as root outside the venv.

---

## 6. Paperclip: `pnpm install` fights the lockfile, or build OOMs

**Symptom A.** `ERR_PNPM_LOCKFILE_...` / "lockfile is not up to date".
**Symptom B.** Node heap out of memory during `pnpm build`, or exit 137.

**Cause A.** A newer global pnpm (10/11) is active. Paperclip pins `pnpm@9.15.4` in its own
`packageManager` field and the lockfile matches *that*.
**Cause B.** Repo-wide build with the default 4 GB heap.

**Fix.** Both are handled: `corepack prepare pnpm@9.15.4 --activate`, then
`HUSKY=0 NODE_OPTIONS=--max-old-space-size=8192 pnpm install --frozen-lockfile && pnpm build`.
If you installed pnpm manually, `corepack enable` first or the pin is ignored.

---

## 7. Paperclip: `onboard` succeeds but the board is unconfigured / 500s

**Symptom.** `pnpm paperclipai onboard` prints success, service starts, board errors or
behaves as if it has no database.

**Cause.** `.env` was missing the `PAPERCLIP_*` block — home, config path, instance id,
deployment mode/exposure, public URL — or `BETTER_AUTH_SECRET`. `onboard` then writes its
config path somewhere the service does not read.

**Fix.** The script writes the full block and `chmod 600 .env`. If you are repairing a box,
copy the block from `install/40-paperclip.sh` step 8, `pnpm db:migrate`, then
`systemctl restart paperclip`.

---

## 8. Paperclip: `unknown option '--bind'`

**Symptom.** `onboard --yes --bind lan` errors on an older release tag.

**Cause.** `--bind` landed in a later tag.

**Fix.** Already handled: the script retries `onboard --yes` and accepts the first run that
produces the config file. Do not hand-write the config.

---

## 9. Paperclip: can't log in

**Symptom.** `http://<ct>:3100/` asks for a login you do not have.

**Cause.** `PAPERCLIP_DEPLOYMENT_MODE=authenticated` is the install default. Accounts are
invite-based.

**Fix.** The CEO invite is generated at install time and written to `/root/paperclip.creds`
inside the container, mode 600, **never** to the install log (which people paste into chat):

```bash
pct exec 122 -- cat /root/paperclip.creds     # invite URL, ~1 hour validity
pct exec 122 -- pnpm --dir /opt/paperclip-ai paperclipai auth bootstrap-ceo   # new invite
```

Do not hand-edit the auth tables in Postgres. Mint a new invite.

---

## 10. Nothing here is TLS

**Symptom.** None — that is the problem. Everything is plain HTTP on your LAN.

**Fix.** Terminate TLS in front (Caddy is two lines per site) or reach the boxes over
Tailscale/WireGuard. Do not port-forward `:3100`, `:3000` or `:8000` to the internet.

---

## 11. Re-running a step

Every step is idempotent: it checks for the thing before it makes the thing.

| Step | Skips when | Forces with |
|---|---|---|
| `create` | `pct status <id>` answers | destroy the CT |
| `twenty` | `/opt/twenty` build output present | `rm -rf /opt/twenty && ./go.sh twenty` |
| `semantica` | venv + unit present | `rm -rf /opt/semantica/venv` |
| `paperclip` | source + `dist` present | `rm -rf /opt/paperclip-ai/node_modules /opt/paperclip-ai/*/dist` |
| `hermes` | `hermes` binary on PATH | `rm -f /usr/local/bin/hermes` |

Re-running never deletes data. It may re-run migrations (safe) and restart units (brief
outage on that service only).
