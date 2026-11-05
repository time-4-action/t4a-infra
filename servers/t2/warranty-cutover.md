# Warranty form cutover: t2 → t4a

How to move Patrik's warranty form (`patrik-international.com`) and its data from t2 to t4a
without losing or corrupting a claim. Everything is prepared; this is the order to do the switch
in, what to check at each step, and how to go back.

| | t2 (`194.28.111.245`) | t4a (`77.42.42.60`) |
|---|---|---|
| State (2026-11-03) | **Live**: customers and t4a-admin use it | **Ready**: same version (`1b0c5a1`), full copy of the data, not public yet |

## What moves and what stays

| Thing | From t2 | To t4a | State |
|---|---|---|---|
| The form (container) | `/data/stack/apps/patrik-international/warranty` | `/srv/patrik-warranty` | running |
| Database `patrik` | t2's MongoDB | t4a's MongoDB (`/srv/mongo`), own user | final copy at cutover |
| `.env` (secrets) | 21 keys | the same 21, only `MONGODB_URI` changed | in place |
| TLS certificate | `/etc/cloudflare-origin/patrik-international` | `/srv/edge/certs/patrik-international.com` | in place |
| `assets.`, `dev-warranty-assets.`, old upload links | nginx proxy to the bucket | Traefik, `/srv/edge/dynamic/patrik-assets.yml` | in place, tested |
| DNS `patrik-international.com`, `www`, `assets` | → t2 | → `77.42.42.60`, proxied | at cutover |
| CI production target | org secrets (t2) | 4 values on the `production` environment | at cutover |

**Doesn't move:** uploaded photos and receipts (bucket `patrik-assets`), the Google Sheet,
SMTP, Sentry, GA, Mapbox, t4a-admin (stays on t2 for now) and its Auth0 roles, the dev
environment (`warranty.dev.patrik-international.com`).

**The data** (checked identical on t2 and t4a on 2026-11-03: count, checksum and indexes of every collection):

| Collection | Documents | What |
|---|---|---|
| `warranty` | 109 | the claims |
| `warranty_audit` | 3 | admin change history |
| `warranty_settings` | 1 | email settings edited in admin |
| `rate_limits` | 0 | spam protection, expires by itself after 2 h (TTL index) |

## How t4a-admin is connected

Admin never opens the `patrik` database. Every claim, note, status change, audit entry and
email setting goes through the form's API at the public address with a shared token
(`WARRANTY_API_BASE=https://www.patrik-international.com`, `INTERNAL_ADMIN_TOKEN`, the same on
both servers). So admin follows DNS: point the name at t4a and admin talks to t4a, with no
change on admin's side.

```
t4a-admin ──https://www.patrik-international.com/api/admin/*──┐
customers ──form, receipt links (/warranty/<id>)──────────────┤
                                                              ▼
                                                  Cloudflare DNS
                                              ┌──────────┴──────────┐
                                     t4a: form + patrik DB   t2: form + patrik DB
                                       (after the switch)    (today; kept for rollback)
```

Only one server gets requests at a time.

## Rules that keep the data safe

1. **One writer at a time.** A claim or an admin change is written by whichever server gets the
   request. The down page goes up before DNS moves, so during the switch neither server accepts writes.
2. **Copy only while frozen.** The final copy runs after t2 has stopped getting requests (its
   nginx log shows nothing new) and while t4a shows the down page.
3. **Identical or don't open.** The down page ends only when every collection matches on both
   servers. If it doesn't, copy again; never fix data by hand.
4. **Leave t2 alone.** Nothing on t2 is changed or deleted during the cutover. Its data is the rollback.

## Already done

- [x] MongoDB on t4a with backups and monitoring (t4a-infra #13)
- [x] Form running on t4a, data copied and checked identical; admin API answers with the real token (109 claims)
- [x] Certificate, bucket routes, deploy key (t4a-infra #16), maintenance banner (t4a-maintenance #2, patrik-warranty-form #24)

## The sequence

About 15 minutes, with a "back soon" page for 2 to 3 of them; evening is quietest. Run the
commands from your machine (SSH hosts `t4a` and `t4a-t2`).

### 0. Optional: announce it on the form (Slack)

An amber banner on the form only, never on the staff apps.

```
/maintenance announce today 21:00 15m for warranty Short maintenance: the warranty form is moving to a new server.
```

### 1. Check both servers are healthy

```sh
curl -s https://patrik-international.com/api/health; echo
ssh t4a 'curl -s http://127.0.0.1:4000/api/health'; echo
```

Go on if both say `"status":"ok"`.

### 2. Turn on the down page (Slack)

Takes effect on t4a's Traefik straight away; t2 keeps serving until step 3, that's expected.

```
/maintenance down patrik-international.com www.patrik-international.com assets.patrik-international.com Moving to a new server, back in a few minutes.
```

### 3. Point DNS at t4a (Cloudflare)

Zone `patrik-international.com`: set the A records `@`, `www` and `assets` to `77.42.42.60`,
keep them **proxied** (orange cloud). Leave every other record, MX included, as it is.

Check: https://patrik-international.com/warranty shows the "back soon" page.

### 4. Wait until t2 gets nothing ⚠️

Give it two minutes, then look at the newest lines of t2's log for the site. Their times must be
older than the DNS change.

```sh
date -u; ssh t4a-t2 'sudo tail -3 /var/log/nginx/patrik-international.com.access.log'
```

**Don't copy yet** if lines keep appearing: wait another minute and look again.

### 5. Final copy of the database ⚠️

Streams `patrik` from t2 straight into t4a and replaces t4a's copy (`--drop`). It reads with the
app's own login from t2's `.env`; nothing is written to t2. A few seconds.

```sh
ssh t4a-t2 "uri=\$(sudo grep -oE 'mongodb://[^[:space:]\"]+' /data/stack/apps/patrik-international/warranty/.env | head -1); mongodump --quiet --uri \"\$uri\" --db patrik --archive --gzip" \
  | ssh t4a "cd /srv/mongo && docker compose exec -T mongo sh -c 'mongorestore --quiet -u \"\$MONGO_INITDB_ROOT_USERNAME\" -p \"\$MONGO_INITDB_ROOT_PASSWORD\" --authenticationDatabase admin --archive --gzip --drop'"
echo "exit codes: ${PIPESTATUS[*]}"
```

Go on if it prints `exit codes: 0 0`.

### 6. Prove the copy is identical ⚠️

Count, checksum (`dbHash`) and indexes of every collection on both servers, then compared.

```sh
cat > ~/cmp.js <<'EOF'
const d = db.getSiblingDB("patrik"), h = d.runCommand({ dbHash: 1 });
d.getCollectionNames().sort().forEach(c => print(c, d.getCollection(c).countDocuments(), h.collections[c],
  JSON.stringify(d.getCollection(c).getIndexes().map(i => [i.key, i.expireAfterSeconds ?? null]))));
EOF
scp -q ~/cmp.js t4a-t2:/tmp/cmp.js && scp -q ~/cmp.js t4a:/tmp/cmp.js
ssh t4a-t2 "uri=\$(sudo grep -oE 'mongodb://[^[:space:]\"]+' /data/stack/apps/patrik-international/warranty/.env | head -1); mongosh --quiet \"\$uri\" /tmp/cmp.js" > ~/cmp-t2.txt
ssh t4a 'cd /srv/mongo && docker compose cp /tmp/cmp.js mongo:/tmp/cmp.js >/dev/null && docker compose exec -T mongo sh -c "mongosh --quiet -u \"\$MONGO_INITDB_ROOT_USERNAME\" -p \"\$MONGO_INITDB_ROOT_PASSWORD\" --authenticationDatabase admin /tmp/cmp.js"' > ~/cmp-t4a.txt
cat ~/cmp-t2.txt; diff ~/cmp-t2.txt ~/cmp-t4a.txt && echo IDENTICAL
```

**Go on only if** it ends with `IDENTICAL`. If not, run step 5 again, then this step. Still
different: go to Rollback.

### 7. Point CI's production at t4a

Four values on the `production` environment of patrik-warranty-form. They override the shared
org secrets for this repo only, so t4a-admin keeps deploying to t2. The last line removes the
private key from t4a once it's in GitHub.

```sh
R=time-4-action/patrik-warranty-form
ssh t4a 'cat /root/patrik-warranty-deploy-key' | gh secret set PROD_DEPLOY_SSH_KEY -e production -R $R
gh secret set PROD_DEPLOY_HOST -e production -R $R --body 77.42.42.60
gh secret set PROD_DEPLOY_FINGERPRINT -e production -R $R --body 'SHA256:S+imWrvzhXtRs0U3VJwAondh5XNv7u8Gw6Sxwcv7HtM'
gh variable set DEPLOY_DIR -e production -R $R --body /srv/patrik-warranty
gh secret list -e production -R $R && ssh t4a 'shred -u /root/patrik-warranty-deploy-key'
```

Check: the list shows the three `PROD_DEPLOY_*` secrets.

### 8. End the down page and check from outside

```
/maintenance end
```

```sh
curl -s https://patrik-international.com/api/health; echo
curl -s -o /dev/null -w "assets %{http_code}\n" https://assets.patrik-international.com/health.json
```

Check: health `ok` with version `1b0c5a1…`, assets `200`. Then by hand: `/warranty` opens, a
receipt link from an old email opens, and in admin.time-4-action.com the Warranty list shows all
claims and one opens.

### 9. Stop the form on t2

Stops it and keeps everything (folder, `.env`, image, t2's database) for rollback.

```sh
ssh t4a-t2 'cd /data/stack/apps/patrik-international/warranty && sudo docker compose stop'
```

## After, the same day

- [x] Merge [patrik-warranty-form #25](https://github.com/time-4-action/patrik-warranty-form/pull/25)
  (`dev` → `main`): the first CI deploy to t4a, with the banner. Approve the production deploy
  when asked; it rolls back by itself if the health check fails.
- [x] Monitoring: in `servers/t4a/monitoring/targets/sites.yml`, `host: t2` → `host: hetzner`
  for "Warranty form"; PR it, copy it to `/srv/monitoring/targets/`.
- [ ] Merge [t4a-infra #16](https://github.com/time-4-action/t4a-infra/pull/16) (already deployed).
- [x] Removed on 2026-11-04, after the form moved on from MongoDB to Postgres on t4a (database
  `patrik-warranty`, patrik-warranty-form #26/#28): t2's container, image, folder, `patrik` database,
  nginx vhosts, origin cert and logs, and t4a's `patrik` Mongo database. Rollback below no longer applies.

## Rollback

Possible at any point, because t2 is never changed. Before step 8 nothing was written on t4a,
so going back loses nothing.

1. Cloudflare: set `@`, `www` and `assets` back to t2's address (proxied).
2. If step 9 was done: `ssh t4a-t2 'cd /data/stack/apps/patrik-international/warranty && sudo docker compose start'`.
3. If step 7 was done: delete the three secrets and `DEPLOY_DIR` from the `production` environment; CI goes back to t2.
4. After step 8, claims may have been written on t4a: copy `patrik` from t4a back to t2 (step 5 with the servers swapped) before t2 takes traffic again.
5. `/maintenance end`.

## Where everything is

| What | Where |
|---|---|
| Form on t4a | `/srv/patrik-warranty` (`docker-compose.yml`, `.env`) |
| Warranty data on t4a | Postgres database `patrik-warranty` in `/srv/postgres` (since 2026-11-04; nightly + point-in-time backups) |
| Form on t2 | removed on 2026-11-04 |
| Bucket routes, certificate | `/srv/edge/dynamic/patrik-assets.yml`, `/srv/edge/certs/patrik-international.com/` |
| More detail | `docs/deployment.md` ("Production on t4a") in patrik-warranty-form; `servers/t4a/README.md` ("MongoDB") here |
