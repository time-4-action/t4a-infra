# Moving everything from t2 to t4a

The whole of t2 (T-2, `194.28.111.245`) moves to t4a (Hetzner, `77.42.42.60`), in waves, without
losing or corrupting data. This file is the plan: what runs on t2, what depends on what, the order,
and the same safe procedure for every wave. The warranty form is the first app wave and has its own
step-by-step file: [`warranty-cutover.md`](warranty-cutover.md).

Inventory checked 2026-11-03. Background: [`README.md`](README.md) (t2) and [`../t4a/README.md`](../t4a/README.md) (t4a).

## What runs on t2

| Service | Public names | Data it keeps | Deploys from | Port |
|---|---|---|---|---|
| patrik-warranty-form | `patrik-international.com`, `www`, `assets` (bucket) | Mongo `patrik` | patrik-warranty-form (`dev` → `main`) | 4000 |
| recharge-si (Partners integration API) | `recharge-sources.time-4-action.com` | Mongo `recharge` | recharge-si/recharge-partners-integration-api | 4545 |
| t4a-mk-automation | `mkauto.time-4-action.com` | files: 783 MB in its folder (`/data`) | t4a-mk-automation | 3000 |
| t4a-partner-portal-api | `api.time-4-action.com` | Mongo `t4a`, files: `export/api/data` (2 MB) | t4a-partner-portal-api | 3001 |
| t4a-partner-portal-ui | `export.time-4-action.com` | none | t4a-partner-portal-ui | 3002 |
| t4a-chat-ui | `chat.time-4-action.com` | Mongo `t4a` | t4a-chat-ui | 3003 (host network) |
| t4a-admin | `admin.time-4-action.com`, `b2b.time-4-action.com` | Mongo `t4a` | t4a-admin | 3005 |
| t4a-mcp + chromadb | `mcp.time-4-action.com` | Mongo `t4a`, files: `chroma_db`, `bm25_indexes`, `uploads` (80 MB) | t4a-mcp | 8000 |
| recharge-hub (web, worker, migrate) | `recharge-hub.time-4-action.com` | its own Postgres 16, database `recharge_hub` 2.8 GB | recharge-si/recharge-hub | 3192 |
| WordPress `patrik-web` | `patrik-web.time-4-action.com` | MariaDB `wp_patrik_web` 113 MB, files 2.8 GB | by hand | nginx + PHP-FPM |
| WordPress `the-chase-project` | `www.the-chase-project.com` | MariaDB `wp_the_chase_project` 11 MB, files 119 MB | by hand | nginx + PHP-FPM |
| WordPress `patrik-test` | none | remote IONOS database | by hand | none |
| Static site | `time-4-action.com`, `www` | one `index.html` | by hand | nginx |
| autodiscover / autoconfig | `autodiscover.`, `autoconfig.time-4-action.com` | config XML | by hand | 8443 |
| Redirects | `*.*.etiam.si` → `export.time-4-action.com`; `*.t4a.etiam.si` | certbot wildcard cert | by hand | nginx |
| Uptime Kuma, Beszel | `status.`, `monitor.time-4-action.com` | Kuma volume 820 MB | by hand | 3333, 8090 |
| Alloy, restic backup | none | none | t4a-infra | none |

All four domains (`time-4-action.com`, `patrik-international.com`, `the-chase-project.com`,
`etiam.si`) are on Cloudflare, so every switch is a DNS change there. Mail is not on t2: don't touch MX.

## What depends on what

**Apps call each other only by public name** (`api.`, `mcp.`, `mkauto.`, `www.patrik-international.com`,
checked in every `.env` on t2). Those follow DNS, so moving one app never breaks another.

**Databases are the only internal links**, and they decide the waves. On t2 the apps reach Mongo at
`172.17.0.1:27017` and Recharge Hub its Postgres at `localhost`; neither is reachable from t4a, so
**an app moves together with its database, and apps that share a database move together**:

| Database | Apps that must move with it |
|---|---|
| Mongo `patrik` | warranty form |
| Mongo `recharge` | recharge-si |
| Mongo `t4a` | partner-portal-api, admin, chat, mcp (one window for all four) |
| Postgres `recharge_hub` | recharge-hub web and worker |
| MariaDB `wp_*` | its WordPress site |

partner-portal-ui and mk-automation have no database and can move on their own.

## Rules for every wave

1. **One writer at a time.** Before DNS moves, the down page goes up (`/maintenance down <names>`), so
   during the switch neither server accepts writes.
2. **Stop the app on t2 before the final copy.** For apps with a worker or background jobs (Hub's
   worker, mk-automation, mcp), the down page isn't enough: stop the containers on t2, then copy.
3. **Copy, then prove it.** Every final copy is followed by a comparison of both sides (Mongo: count,
   checksum and indexes per collection; Postgres and MariaDB: exact row count per table; files: size
   and file count). The down page ends only when they match. Never fix data by hand.
4. **Never change or delete anything on t2 during a wave.** t2 is the rollback until the very end.
5. **One wave per window**, and check the next morning (daily summary, Grafana, the apps) before the next.

## Before the first wave: once per app

Each repo needs the same small change the warranty form got (patrik-warranty-form #24), as a PR in
that repo. Merging it changes nothing until that repo's `production` environment gets the t4a values.

- **The deploy folder from a variable**: in `.github/workflows/deploy.yml`,
  `cd ${{ vars.DEPLOY_DIR || '/data/stack/apps/<today's path>' }}`.
- **`deploy/docker-compose.t4a.yml`**: Traefik labels for its names (`traefik.enable=true`, a unique
  router name, `loadbalancer.server.port`), the `edge` network plus `mongo` and/or `db` if it has a
  database, its port on `127.0.0.1` only (for CI's health check; never `0.0.0.0`), `mem_limit`,
  log rotation. chat stops using the host network.
- **The switch, per repo**: on its `production` environment, the secrets `PROD_DEPLOY_HOST`
  (`77.42.42.60`), `PROD_DEPLOY_SSH_KEY` (a new key `github-actions@<repo>` in `deploy`'s
  `authorized_keys` on t4a), `PROD_DEPLOY_FINGERPRINT` (`SHA256:S+imWrvzhXtRs0U3VJwAondh5XNv7u8Gw6Sxwcv7HtM`)
  and the variable `DEPLOY_DIR` (`/srv/<app>`). They override the shared org secrets for that repo
  only, so the apps still on t2 keep deploying to t2. The Recharge repos are in the `recharge-si`
  org with its own org secrets: same approach.

Preparing an app on t4a (no effect on the live site, see the warranty form for a worked example):
folder `/srv/<app>` owned by `deploy` with `docker-compose.yml` and the `.env` copied from t2
(streamed, never printed), with only the database URL changed; a database user from
`new-app-mongo.sh` / `new-app-db.sh`; the image (CI, or `docker save` from t2); a trial copy of the
data plus the comparison; start it and check `http://127.0.0.1:<port>/api/health` (or its page) on t4a.

## The waves, in order

Small and independent first, to practise the procedure; the shared `t4a` database in the middle,
with the procedure well known by then; the big ones last.

| Wave | What | Data | Down page for | Risk |
|---|---|---|---|---|
| 0 ✅ | Mongo, backups, monitoring on t4a | none | none | done |
| 1 | Static `time-4-action.com`, WordPress `the-chase-project` | 11 MB DB, 119 MB files | `www.the-chase-project.com` | low |
| 2 | **Warranty form** ([runbook](warranty-cutover.md)) | Mongo `patrik` | `patrik-international.com`, `www`, `assets` | low, prepared |
| 3 | recharge-si | Mongo `recharge` (5.3k docs) | `recharge-sources.` | low |
| 4 | mk-automation, partner-portal-ui | 783 MB files (mk) | `mkauto.`, `export.` | low |
| 5 | **The `t4a` group**: partner-portal-api, admin (+ `b2b.`), chat, mcp + chromadb | Mongo `t4a` (34 collections, 31k docs), mcp and api files | `api.`, `admin.`, `b2b.`, `chat.`, `mcp.` | high: four apps, one window |
| 6 | recharge-hub | Postgres 2.8 GB (16 → 18) | `recharge-hub.` | medium: largest copy |
| 7 | WordPress `patrik-web` | 113 MB DB, 2.8 GB files | `patrik-web.` | medium: WPML, Enfold on PHP 8.5, `.htaccess` |
| 8 | autodiscover/autoconfig, etiam.si redirects, retire Kuma and Beszel | none | none | low |
| 9 | Retire t2 | final backup | none | see below |

Decide before the wave it belongs to:
- **Wave 7**: `patrik-test` and its IONOS database (archive or drop; it has no site).
- **Wave 8**: autodiscover/autoconfig (move as a small container, or retire if nobody sets up new
  mail clients for `mx1.t-2.si`). `*.t4a.etiam.si` needs its own certificate (two levels deep,
  Cloudflare's free one covers one); check t2's nginx log whether anything still uses it, and retire it if not.
- Names nobody uses (no traffic): `warranty-preview.` and `dev-warranty.time-4-action.com`, retire.

## A wave, step by step

The same for every app. The warranty form's file has this with every command filled in.

1. **Ready on t4a**: prepared as above, trial copy compared identical, health check ok on loopback.
2. Optional: `/maintenance announce <day> <time> <length> for <apps> <message>` (staff apps:
   `portal`, `hub`, `admin`, `chat`; the warranty form only with `for warranty`).
3. `/maintenance down <every public name of the wave>`.
4. Cloudflare: point those A records at `77.42.42.60`, proxied. Leave every other record alone.
5. Wait until t2's nginx log for those names shows nothing new (`sudo tail` of
   `/var/log/nginx/<name>.access.log`), then **stop the wave's containers on t2**
   (`sudo docker compose stop` in their folders).
6. **Final copy** of each database and data folder (commands below).
7. **Compare** (commands below). Different: copy again. Still different: roll back.
8. Set the repo's four `production` values (CI now deploys there); remove the key from t4a afterwards.
9. `/maintenance end`; check from outside (health, a page, a login, one real action in the app).
10. Monitoring: in `../t4a/monitoring/targets/sites.yml`, `host: t2` → `host: hetzner` for the wave's entries.
11. Next morning: the daily summary has no red lines, Grafana shows the apps, and t4a's nightly
    backup contains the new data. Only then the next wave.

**Rollback** at any point: DNS back to t2's address, `sudo docker compose start` on t2, delete the
repo's `production` values. If the app already wrote on t4a, copy its data back to t2 first (the same
commands, servers swapped).

## Copy and compare commands

Run from your machine (SSH hosts `t4a` and `t4a-t2`).

### Mongo, one database (`<db>`: `patrik`, `recharge` or `t4a`)

Copy, reading with one app's own login from its `.env` on t2 (`<env>`: `patrik-international/warranty/.env`,
`recharge-si/.env`, `time-4-action/mcp/.env`):

```sh
ssh t4a-t2 "uri=\$(sudo grep -oE 'mongodb://[^[:space:]\"]+' /data/stack/apps/<env> | head -1); mongodump --quiet --uri \"\$uri\" --db <db> --archive --gzip" \
  | ssh t4a "cd /srv/mongo && docker compose exec -T mongo sh -c 'mongorestore --quiet -u \"\$MONGO_INITDB_ROOT_USERNAME\" -p \"\$MONGO_INITDB_ROOT_PASSWORD\" --authenticationDatabase admin --archive --gzip --drop'"
echo "exit codes: ${PIPESTATUS[*]}"
```

Compare (count, checksum, indexes of every collection):

```sh
DB=<db>; ENV=<env>
cat > ~/cmp.js <<EOF
const d = db.getSiblingDB("$DB"), h = d.runCommand({ dbHash: 1 });
d.getCollectionNames().sort().forEach(c => print(c, d.getCollection(c).countDocuments(), h.collections[c],
  JSON.stringify(d.getCollection(c).getIndexes().map(i => [i.key, i.expireAfterSeconds ?? null]))));
EOF
scp -q ~/cmp.js t4a-t2:/tmp/cmp.js && scp -q ~/cmp.js t4a:/tmp/cmp.js
ssh t4a-t2 "uri=\$(sudo grep -oE 'mongodb://[^[:space:]\"]+' /data/stack/apps/$ENV | head -1); mongosh --quiet \"\$uri\" /tmp/cmp.js" > ~/cmp-t2.txt
ssh t4a 'cd /srv/mongo && docker compose cp /tmp/cmp.js mongo:/tmp/cmp.js >/dev/null && docker compose exec -T mongo sh -c "mongosh --quiet -u \"\$MONGO_INITDB_ROOT_USERNAME\" -p \"\$MONGO_INITDB_ROOT_PASSWORD\" --authenticationDatabase admin /tmp/cmp.js"' > ~/cmp-t4a.txt
cat ~/cmp-t2.txt; diff ~/cmp-t2.txt ~/cmp-t4a.txt && echo IDENTICAL
```

Each app sharing `t4a` gets its own user on it: `ssh t4a sh /srv/mongo/new-app-mongo.sh <app> t4a`
(prints that app's `MONGODB_URI`; put it in the app's `.env` on t4a).

### Postgres, Recharge Hub (16 on t2 → the shared 18 on t4a)

Once: `ssh t4a sh /srv/postgres/new-app-db.sh recharge_hub` creates the role and database and prints
`DATABASE_URL` for Hub's `.env` on t4a. Then, with web and worker stopped on t2:

```sh
ssh t4a-t2 'u=$(sudo docker exec recharge-hub-postgres-1 printenv POSTGRES_USER); sudo docker exec recharge-hub-postgres-1 pg_dump -U "$u" -Fc recharge_hub' \
  | ssh t4a 'cd /srv/postgres && docker compose exec -T postgres pg_restore -U postgres -d recharge_hub --no-owner --role=recharge_hub --clean --if-exists --exit-on-error'
echo "exit codes: ${PIPESTATUS[*]}"
```

Compare (exact row count of every table):

```sh
Q="SELECT table_name, (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY 1"
ssh t4a-t2 "u=\$(sudo docker exec recharge-hub-postgres-1 printenv POSTGRES_USER); sudo docker exec recharge-hub-postgres-1 psql -U \"\$u\" -d recharge_hub -Atc \"$Q\"" > ~/pg-t2.txt
ssh t4a "cd /srv/postgres && docker compose exec -T postgres psql -U postgres -d recharge_hub -Atc \"$Q\"" > ~/pg-t4a.txt
wc -l ~/pg-t2.txt; diff ~/pg-t2.txt ~/pg-t4a.txt && echo IDENTICAL
```

Do a trial run a day ahead to know how long it takes (2.8 GB: a few minutes). Hub's `migrate`
service on t4a then finds nothing to do. Shopify retries webhooks it couldn't deliver during the window.

### MariaDB, one WordPress site

Create the site first (`sh /srv/wordpress/new-site.sh <site> <domain>...`, `../t4a/README.md`, "WordPress"),
then, with the down page on:

```sh
ssh t4a-t2 'sudo mysqldump --single-transaction --routines --events <t2 database>' \
  | ssh t4a 'cd /srv/mariadb && docker compose exec -T mariadb sh -c "mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\" wp_<site>"'
```

Compare (exact row count of every table):

```sh
T2DB=<t2 database>; T4DB=wp_<site>
CNT="SELECT CONCAT('SELECT ''', table_name, ''', COUNT(*) FROM ', CHAR(96), table_name, CHAR(96), ';') FROM information_schema.tables WHERE table_schema = DATABASE() ORDER BY table_name;"
my2() { ssh t4a-t2 "sudo mysql -N $T2DB"; }
my4() { ssh t4a "cd /srv/mariadb && docker compose exec -T mariadb sh -c 'mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\" -N $T4DB'"; }
echo "$CNT" | my2 | my2 > ~/my-t2.txt
echo "$CNT" | my4 | my4 > ~/my-t4a.txt
cat ~/my-t2.txt; diff ~/my-t2.txt ~/my-t4a.txt && echo IDENTICAL
```

(The first query writes one `SELECT COUNT(*)` per table, the second runs them. Tested on both servers 2026-11-03.)

Files: stream them (t2's `/data` is too full to stage a copy), leaving out what must not move
(for `patrik-web`: `db577760631_2024-05-20.dump`, `phpinfo.php`, `wp-config_*.php`):

```sh
ssh t4a-t2 'sudo tar -C /mnt/vdc/www/t4a/<site> --exclude=<file> -cf - .' | ssh t4a 'tar -C /srv/wordpress/<site>/html -xf - && chown -R 33:33 /srv/wordpress/<site>/html'
```

Then point the site's own `wp-config.php` at `DB_HOST mariadb` with the user from its `.env`, keep
the table prefix, review `.htaccess` (t4a runs Apache, which applies it; nginx on t2 ignored it),
and test WPML and Enfold on PHP 8.5 before the switch.

### App data folders (mk-automation, mcp, partner-portal-api)

With the app stopped on t2 (for mcp, also `t4a-chromadb`, so ChromaDB's files are consistent):

```sh
ssh t4a-t2 'sudo tar -C /data/stack/apps/<path> -cf - <folders>' | ssh t4a 'tar -C /srv/<app> -xf - && chown -R deploy:deploy /srv/<app>'
ssh t4a-t2 'cd /data/stack/apps/<path> && sudo find <folders> -type f | wc -l; sudo du -sb <folders>'
ssh t4a 'cd /srv/<app> && find <folders> -type f | wc -l; du -sb <folders>'
```

Same file count and byte size on both sides, or copy again. `<folders>`: mk-automation its whole
folder except `.env` and the compose file (`/data` inside the container); mcp `chroma_db bm25_indexes uploads`;
partner-portal-api `data`.

## Wave 9: retire t2

When every app has run on t4a for at least a week without problems:

1. Org secrets: set `PROD_DEPLOY_HOST`, `PROD_DEPLOY_SSH_KEY`, `PROD_DEPLOY_FINGERPRINT` in both
   orgs (`time-4-action`, `recharge-si`) to t4a, then delete the per-repo `production` overrides.
   Change `DEPLOY_DIR` defaults in the workflows to the `/srv/...` paths.
2. Last restic backup on t2 (`sudo systemctl start t4a-backup.service`), check it in Backrest.
3. Stop, don't delete: every container, nginx, PHP-FPM, MariaDB, MongoDB, the restic timer, Alloy.
   Grafana will alert "Server stopped reporting" for t2: expected; remove t2 from monitoring after.
4. Cloudflare: remove the records nobody needs any more (`status.`, `monitor.`, `warranty-preview.`,
   `dev-warranty.`, and whatever wave 8 retired).
5. Keep t2 and its restic repo (`restic/t4a-t2`) for a few weeks; then cancel t2. Archive
   `/data/stack/apps/mail-migration` and `/home/almalinux` first (may hold credentials).

## Status

| Wave | State |
|---|---|
| 0 | done 2026-11-02 (t4a-infra #13, #14) |
| 1 | not started |
| 2 | prepared 2026-11-03, waiting for the cutover ([runbook](warranty-cutover.md)) |
| 3–9 | not started |
