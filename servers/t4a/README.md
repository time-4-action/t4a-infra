# Server `t4a` (Hetzner)

`77.42.42.60`, Hetzner Cloud (Helsinki), Ubuntu 26.04, 4 vCPU, 8 GB RAM, 2 GB swap
(`/swapfile`, `vm.swappiness=10`), 75 GB disk. SSH as `root` (admin) or `deploy`
(CI, in the `docker` group). Hostname `time-4-action-production`.

Runs jakamarinko (`/srv/jakamarinko`), rokomet-stats (`/srv/rokomet-stats`) and
ld-docs (`/srv/ld-docs`). Each app deploys itself from its own repo; this folder
holds only the server-wide parts in `/srv/edge`, `/srv/postgres`, `/srv/mariadb`,
`/srv/wordpress`, the ops tools `/srv/pghero` and `/srv/backrest`, `/srv/maintenance`, the
monitoring for both servers in `/srv/monitoring`, and the backups.
None of it is deployed by CI: change it here, open a pull request, then copy it
to the server by hand as described in each section.

```
Browser ─HTTPS─> Cloudflare (proxy) ─HTTPS, origin cert─> Traefik :443 (/srv/edge) ──> app containers
                                                                         apps ──db network──> Postgres (/srv/postgres)
```

## Edge proxy (`edge/` → `/srv/edge`)

One Traefik owns :443 for every app. ufw allows only 22 and 443.
```
scp edge/compose.yml edge/traefik.yml t4a:/srv/edge/
scp edge/dynamic/*.yml t4a:/srv/edge/dynamic/     # picked up live, no restart
ssh t4a 'cd /srv/edge && docker compose up -d'
```
- `dynamic/tls.yml`: one Cloudflare origin cert per zone in `/srv/edge/certs/<zone>/`, picked by SNI.
- `dynamic/middlewares.yml`: `cloudflare-only` (403 unless from https://www.cloudflare.com/ips/; Docker-published ports skip ufw) and `compress`, on every route. If Cloudflare changes its ranges, update this file and `traefik.yml`.
- Adding an app: put its web service on the external `edge` network with the labels `traefik.enable=true`, `traefik.http.routers.<name>.rule=Host(\`example.com\`)` and `traefik.http.services.<name>.loadbalancer.server.port=<port>` (router names unique on the server). New Cloudflare zone: add its origin cert to `/srv/edge/certs/<zone>/` and `dynamic/tls.yml`.
- Never publish an app port on `0.0.0.0`: Docker bypasses ufw. Use the `edge` network, or `127.0.0.1:<port>` if something on the host needs it.
- Metrics: the `metrics` entrypoint (`:8082`, not published) serves Prometheus metrics per router, service and entrypoint; `monitoring/` scrapes it as `traefik:8082`. Changing `traefik.yml` needs `docker compose restart traefik` (a second or two without any site).

## Postgres (`postgres/` → `/srv/postgres`)

One Postgres 18 for every app, one database and owner role per app. No published
port: apps join the external `db` network and connect to `postgres:5432`.

| File | What |
|---|---|
| `Dockerfile` | `postgres:18.6-alpine` plus pgBackRest. Built on the server (`docker compose build`). |
| `postgresql.conf` | The whole server config (memory, WAL, archiving, logging). Mounted read-only, replaces the initdb default in `$PGDATA`. |
| `pgbackrest.conf` | Backup repo on the Storage Box (below). |
| `new-app-db.sh` | `ssh t4a sh /srv/postgres/new-app-db.sh <name>` creates a role (max 30 connections) and database, prints a `DATABASE_URL` for that app's `.env`. |
| `pg-backup`, `pg-backup.cron` | Nightly base backup → `/usr/local/bin/pg-backup`, `/etc/cron.d/pg-backup`. |
| `restore-drill` | Restore test (below). |
| `logrotate` | → `/etc/logrotate.d/t4a-postgres`. |

Not in git, only on the server: `/srv/postgres/.env` (`POSTGRES_PASSWORD`,
`PGBACKREST_REPO1_CIPHER_PASS`, mode 600) and `/srv/postgres/pgbackrest-ssh/`
(pgBackRest's Storage Box key `pgbackrest@t4a` and the Storage Box host keys,
owned by uid 70, mode 600).

- psql: `ssh -t t4a 'cd /srv/postgres && docker compose exec postgres psql -U postgres <db>'`
- Slowest queries: `SELECT query, calls, mean_exec_time FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 20;` (run `CREATE EXTENSION IF NOT EXISTS pg_stat_statements;` once per database). Statements over 500 ms are also in `docker compose logs postgres`.
- Change the config:
  ```
  scp postgres/postgresql.conf postgres/pgbackrest.conf postgres/compose.yml postgres/Dockerfile t4a:/srv/postgres/
  ssh t4a 'cd /srv/postgres && docker compose build && docker compose up -d'
  ```
  `up -d` restarts Postgres when the image, compose file or `postgresql.conf` changed (10-15 s; apps reconnect). Settings that don't need a restart: `docker compose exec postgres psql -U postgres -c 'SELECT pg_reload_conf()'`.
- Minor upgrade (18.x): bump the tag in `Dockerfile` and `compose.yml` (`image:`), then the commands above. Major upgrade (19): dump and restore into a new volume, or `pg_upgrade`; plan it, it's not a tag bump. A new major also needs a new pgBackRest stanza upgrade (`pgbackrest --stanza=main stanza-upgrade`).
- `stop_grace_period: 2m`: Docker would otherwise SIGKILL Postgres after 10 s, forcing crash recovery on the next start.

## MariaDB (`mariadb/` → `/srv/mariadb`)

MariaDB 11.4 LTS for the WordPress sites only; apps use Postgres. No published port:
sites join the external `mariadb` network and connect to `mariadb:3306`. `root` works only
from inside the container (`MARIADB_ROOT_HOST=localhost`); its password is in
`/srv/mariadb/.env` (mode 600). Each site has its own database and user, limited to 20
connections.

- `my.cnf`: 256 MB buffer pool, 60 connections, utf8mb4, performance_schema off, slow
  queries over 1 s in `slow.log` inside the volume (rotated by `postgres/logrotate`).
  Don't set `collation-server`: in 11.4 a non-default one breaks the users dump in the backup.
- SQL shell: `ssh -t t4a 'cd /srv/mariadb && docker compose exec mariadb sh -c "mariadb -uroot -p\$MARIADB_ROOT_PASSWORD"'`
- Change the config or bump the minor version: `scp mariadb/* t4a:/srv/mariadb/ && ssh t4a 'cd /srv/mariadb && docker compose up -d'`
  (restarts MariaDB, a few seconds; `MARIADB_AUTO_UPGRADE` runs `mariadb-upgrade`).
  A major upgrade (12.x): dump and restore into a new volume.

## WordPress (`wordpress/` → `/srv/wordpress`)

Each site is its own container (`wordpress:<version>-php8.5-apache`, 512 MB memory limit)
on the `edge` and `mariadb` networks, routed by Traefik. Its files live in
`/srv/wordpress/<site>/html`, so the nightly restic backup of `/srv` covers them;
the database is in the nightly MariaDB dump.

- New site: `ssh t4a sh /srv/wordpress/new-site.sh <site> <domain> [<domain> ...]`. It creates
  database and user `wp_<site>`, `/srv/wordpress/<site>/` (compose.yml, php.ini, .env, html/)
  and starts the container. Then in Cloudflare: an A record for each domain → `77.42.42.60`,
  proxied; a new zone also needs its origin certificate (Edge proxy above). Open
  `https://<domain>/wp-admin/install.php` to finish.
- PHP version per site: `WP_IMAGE_TAG` in the site's `.env` (default `7.1.3-php8.5-apache`),
  then `docker compose up -d` in its folder. The WordPress version in the tag only matters on
  the first start; afterwards core, themes and plugins update from wp-admin.
- PHP limits per site in its `php.ini` (64 MB uploads, 256 MB memory).
- wp-config.php written on first start reads the database settings from `.env`, forces HTTPS
  behind the proxy and sets `DISALLOW_FILE_EDIT`.
- WP-CLI: `docker run --rm --network mariadb --user 33:33 --env-file /srv/wordpress/<site>/.env -e WORDPRESS_DB_HOST=mariadb -v /srv/wordpress/<site>/html:/var/www/html wordpress:cli-2.12.0-php8.5 wp <command>`
- Moving an existing site in: copy its files into `html/`, import its dump into `wp_<site>`
  (`docker compose exec -T mariadb sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" wp_<site>' < dump.sql`),
  and point its own `wp-config.php` at `DB_HOST mariadb` with the user and password from `.env`.
- Remove a site: `docker compose down` in its folder, delete the folder, `DROP DATABASE wp_<site>; DROP USER wp_<site>@'%';`.

Tested 2026-10-25 with a throwaway site: install, a published post served with 200, routing
through Traefik, backup to the Storage Box and a restore of its database. Then removed.

## Ops tools (`pghero/` → `/srv/pghero`, `backrest/` → `/srv/backrest`)

Two web UIs behind Traefik, both behind one basic-auth login (`ops-auth` middleware in
`/srv/edge/dynamic/ops-auth.yml`, not in git; user and password in `/root/ops-login`). The same login
guards https://maintenance.time-4-action.com/admin; `headerField: X-Forwarded-User` in that file passes
the user name on, and the maintenance service relies on it.
Cloudflare: proxied A records `pghero` and `backrest` in `time-4-action.com` → `77.42.42.60`.

- **PgHero**, https://pghero.time-4-action.com: slow queries (`pg_stat_statements`), table and
  index sizes, unused and duplicate indexes, connections, per database. Connects as the role
  `pghero` (`pg_monitor`, 5 connections, can't read table data; EXPLAIN is off); its password
  is `PGHERO_DB_PASSWORD` in `/srv/pghero/.env`. Don't name it `PGHERO_PASSWORD`: PgHero
  reads that as its own login. A new database: `new-app-db.sh` already grants `pghero`
  CONNECT and adds `pg_stat_statements`; add an entry to `pghero.yml`, then
  `scp pghero/pghero.yml t4a:/srv/pghero/ && ssh t4a 'cd /srv/pghero && docker compose restart'`.
- **Backrest**, https://backrest.time-4-action.com: both servers' restic repos,
  `t4a-production` (this server) and `t4a-t2` (t2's, added 2026-10-28). Browse snapshots, see
  sizes, restore or download single files. It uses root's Storage Box key (`/root/.ssh`),
  `/root/.restic-password` and `/root/.restic-password-t2` (t2's, copied from its
  `RESTIC_PASSWORD_FILE`), mounted read-only. It runs no backups, prunes or checks: `t4a-backup`
  on each server owns its repo and retention, so don't use Backrest's forget or prune buttons.
  Because of that it only lists snapshots after indexing a repo: `backrest-index.cron`
  (→ `/etc/cron.d/backrest-index`) does `t4a-production` at 04:30 and `t4a-t2` at 05:40, after each
  server's backup and t2's Sunday prune. Its dashboard card says "No backups yet" (it counts only
  backups Backrest runs); the snapshots are under each repo in the sidebar.
  Backrest's own login is off (`auth.disabled`); the basic auth in front is the login.
  Backrest rewrites `config/config.json` when settings change in the UI; copy it back
  into git if you change anything there, without its `sync` section (Backrest's private
  identity key; it stays on the server, and Backrest makes a new one if it's missing).

Deploy or update:
```
scp pghero/compose.yml pghero/pghero.yml t4a:/srv/pghero/
scp backrest/compose.yml t4a:/srv/backrest/ && scp backrest/config.json t4a:/srv/backrest/config/
ssh t4a 'cd /srv/pghero && docker compose up -d; cd /srv/backrest && docker compose up -d'
```
Set up once on 2026-10-25: the `pghero` role (`CREATE ROLE pghero LOGIN PASSWORD '...'
CONNECTION LIMIT 5; GRANT pg_monitor TO pghero;` plus `GRANT CONNECT` and
`pg_stat_statements` per database), `/srv/pghero/.env`, `ops-auth.yml` (hash from
`openssl passwd -apr1`), and the `time-4-action.com` origin cert copied from t2.

## Monitoring (`monitoring/` → `/srv/monitoring`)

Metrics, logs, dashboards and alerts for both servers and every site and API:
https://grafana.time-4-action.com, behind the ops login (Grafana trusts the user name the
`ops-auth` middleware passes in `X-Forwarded-User`; it has no login form of its own). Its
home page is the **Overview** dashboard: every site and API with status and response time,
every backup on both servers with its age and size (red over 26 h; from `t4a-backup-metrics`
in `servers/alerts`, read by Alloy's textfile collector), both servers' CPU, RAM and disks, requests, 5xx errors and p95 latency per app behind Traefik,
every container's RAM and CPU, and the latest error lines from all logs.

```
t4a: Alloy ──127.0.0.1──> Prometheus, Loki <── Grafana ──> Slack #t4a-server
t2:  Alloy ──https://ingest.time-4-action.com (ingest-auth)──┘
Prometheus also scrapes: Traefik :8082, blackbox (targets/sites.yml), postgres-exporter, mariadb-exporter
```

| Service | What |
|---|---|
| `prometheus` | Metrics, 30 days or 8 GB, whichever is smaller. Accepts remote write (Alloy). `127.0.0.1:9090` on the host. |
| `loki` | Logs of every container on both servers, 30 days. `127.0.0.1:3100` on the host. |
| `grafana` | Dashboards (`grafana/dashboards/*.json`, read-only in the UI) and alerts (`grafana/provisioning/alerting/`). |
| `alloy` | This server's collector: host metrics, per-container CPU/RAM/network/disk I/O (cAdvisor) and every container's logs. Host network, pid and cgroup; `config.alloy` is shared with t2. |
| `blackbox` | Checks every URL in `targets/sites.yml` from here every 30 s. |
| `postgres-exporter`, `mariadb-exporter` | Database metrics, as the read-only users `metrics` (Postgres `pg_monitor`, MariaDB `PROCESS, BINLOG MONITOR, SLAVE MONITOR`), 3 connections each. |

Alerts (13 rules in `rules.yml`, all to `#t4a-server` through the "t4a server" Slack app,
`SLACK_BOT_TOKEN` from `/etc/t4a-slack.env`): site or API down 3 min, slow over 5 s, certificate
under 14 days, over 5 % 5xx on an app, disk over 85 %, RAM under 10 %, CPU over 90 % for 15 min,
a server stopped reporting, a container restarting, a scrape target down, a database down,
a backup older than 26 h, a backup whose state can't be read for 2 h.
Summaries are Go templates (`{{ $labels.name }}`); Grafana does not expand environment variables
in rule files, so a `$` stays as it is.

Not in git, only on the server:
- `/srv/monitoring/.env` (mode 600): `PG_METRICS_PASSWORD`, `MARIADB_METRICS_PASSWORD`, `GF_SECURITY_ADMIN_PASSWORD`.
- `/srv/edge/dynamic/ingest-auth.yml`: basic auth `t2` for https://ingest.time-4-action.com; the
  password is in `/root/ingest-login` and in `/data/stack/monitoring/.env` on t2.

Cloudflare: proxied A records `grafana` and `ingest` in `time-4-action.com` → `77.42.42.60`.

- A new site or API to check: add it to `targets/sites.yml` (`http_2xx` must answer 2xx;
  `http_login` counts a redirect or 401 to a login as up), then
  `scp monitoring/targets/sites.yml t4a:/srv/monitoring/targets/`. Prometheus re-reads it, no restart.
- A new dashboard: export its JSON from Grafana, put it in `grafana/dashboards/` with datasource uids
  `prometheus` / `loki`, copy it over; Grafana loads it within a minute.
- Deploy or update:
  ```
  scp -r monitoring/compose.yml monitoring/prometheus.yml monitoring/loki.yml monitoring/blackbox.yml monitoring/targets monitoring/alloy monitoring/grafana t4a:/srv/monitoring/
  ssh t4a 'cd /srv/monitoring && docker compose up -d && docker compose restart grafana prometheus alloy'
  ```
  `config.alloy` also goes to t2 (`servers/t2/README.md`).
- Docker 29 detail: cAdvisor reaches Docker through containerd, so Alloy mounts
  `/run/containerd/containerd.sock` and runs with `cgroup: host`; without either it sees no containers.
  Its `disk` collector is off: it walks every container's files and kept t2 in iowait.

Set up on 2026-10-28: the `metrics` users (`CREATE ROLE metrics LOGIN CONNECTION LIMIT 3; GRANT
pg_monitor TO metrics;` and `CREATE USER metrics@'%' ... WITH MAX_USER_CONNECTIONS 3; GRANT PROCESS,
BINLOG MONITOR, SLAVE MONITOR ON *.* TO metrics@'%';`), `.env`, `ingest-auth.yml` (hash from
`openssl passwd -apr1`), the two DNS records, and Traefik's metrics entrypoint.

## Maintenance (`/srv/maintenance`, its own repo)

Maintenance banners and down pages (web page `/admin` and the `/maintenance` Slack command) live in
[time-4-action/t4a-maintenance](https://github.com/time-4-action/t4a-maintenance), which
deploys itself to `/srv/maintenance` as `deploy` on merge; its README has the commands and setup.
What it needs from this server: the `edge` network, `/srv/edge/dynamic/maintenance.yml` (owned by
`deploy`, where it writes the down-mode router), and the proxied A record `maintenance` → `77.42.42.60`.

## Backups

Two independent copies, both on Hetzner Storage Box `u578499` (`u578499.your-storagebox.de`, port 23).
`restic/t4a-t2` on the same box belongs to the other server (t2): never back up, forget or prune
it from here. Backrest only reads it (browse and restore).

**1. pgBackRest, point-in-time recovery** (repo `/home/pgbackrest/t4a-production`, AES-256 encrypted)
- Postgres archives every WAL segment as it fills, and at least every 5 minutes (`archive_timeout`). A lost server costs at most ~5 minutes of writes.
- `/etc/cron.d/pg-backup` runs `pg-backup` at 02:30: full backup on Sundays, differential the other days, then `pgbackrest check`. Keeps 2 full backups, so any minute of the last 1-2 weeks can be restored. Log: `/var/log/pg-backup.log`.
- If the Storage Box is unreachable, WAL queues on t4a up to 4 GB and is then dropped (`archive-push-queue-max`) rather than filling the disk. Point-in-time recovery is broken from then until the next full backup; `pgbackrest info` and the heartbeat show it.
- State: `ssh t4a 'cd /srv/postgres && docker compose exec -u postgres postgres pgbackrest --stanza=main info'`

**2. restic, nightly dumps and files** (repo `restic/t4a-production`, `/root/.restic-password`)
- `/etc/cron.d/t4a-backup` runs `t4a-backup` at 04:00 (after rokomet's 03:30 `app.db` copy): `pg_dump` of every database to `/var/backups/postgres`, `mariadb-dump` of every MariaDB database plus users and grants to `/var/backups/mariadb`, then restic of those dumps, `/srv` (every `.env`, compose file, cert, `pgbackrest-ssh`, WordPress files), `/etc/cron.d` and `/usr/local/bin`. Keeps 7 daily, 4 weekly, 6 monthly; Sundays reads back 5 %. Log: `/var/log/t4a-backup.log`.

**Keep copies outside t4a** of `/root/.restic-password` and `PGBACKREST_REPO1_CIPHER_PASS` from `/srv/postgres/.env` (password manager). Without them neither backup can be read.

**Slack.** Both crons run through `t4a-run`, which posts to `#t4a-server` when a backup fails; a summary of every backup follows each morning at 05:00 UTC. See [`../alerts/README.md`](../alerts/README.md).

**Heartbeats.** Both scripts ping a URL when they succeed, read from `/etc/t4a-heartbeat.env`:
```
T4A_BACKUP_HEARTBEAT_URL=https://...   # restic, daily
PG_BACKUP_HEARTBEAT_URL=https://...    # pgBackRest, daily
```
Point them at push monitors that alert when a ping is missing for 25 h (Uptime Kuma "Push", healthchecks.io).

### Restore

Restore drill (read-only for live apart from a marker row in `postgres.restore_drill`): `ssh t4a sh /srv/postgres/restore-drill`. It writes a marker after the last backup, restores the repo into a scratch container with archiving off, checks the marker and every table's row count, and removes the scratch. Run it after any backup change and once a month. Last run: 2026-10-25, passed.

Whole server to a point in time (stops every app's database):
```
cd /srv/postgres && docker compose stop postgres
docker run --rm -u postgres --env-file .env -v postgres_pg_data:/var/lib/postgresql \
  -v $PWD/pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro -v $PWD/pgbackrest-ssh:/etc/pgbackrest/ssh:ro \
  t4a/postgres:18.6-pgbackrest2.58 \
  pgbackrest --stanza=main --delta --type=time --target='2026-10-25 09:00:00+00' --target-action=promote restore
docker compose up -d
```
One database from last night's dump instead:
```
export RESTIC_REPOSITORY=sftp:storagebox:restic/t4a-production RESTIC_PASSWORD_FILE=/root/.restic-password
restic dump latest /var/backups/postgres/<db>.dump | docker exec -i postgres-postgres-1 pg_restore -U postgres -d <db> --clean
restic restore latest --target /tmp/restore --include /srv/<app>    # files
```
