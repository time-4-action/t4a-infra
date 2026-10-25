# Server `t4a` (Hetzner)

`77.42.42.60`, Hetzner Cloud (Helsinki), Ubuntu 26.04, 4 vCPU, 8 GB RAM, 2 GB swap
(`/swapfile`, `vm.swappiness=10`), 75 GB disk. SSH as `root` (admin) or `deploy`
(CI, in the `docker` group). Hostname `time-4-action-production`.

Runs jakamarinko (`/srv/jakamarinko`), rokomet-stats (`/srv/rokomet-stats`) and
ld-docs (`/srv/ld-docs`). Each app deploys itself from its own repo; this folder
holds only the server-wide parts in `/srv/edge`, `/srv/postgres` and the backups.
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

## Backups

Two independent copies, both on Hetzner Storage Box `u578499` (`u578499.your-storagebox.de`, port 23).
`restic/t4a-t2` on the same box belongs to the other server (t2): never touch it.

**1. pgBackRest, point-in-time recovery** (repo `/home/pgbackrest/t4a-production`, AES-256 encrypted)
- Postgres archives every WAL segment as it fills, and at least every 5 minutes (`archive_timeout`). A lost server costs at most ~5 minutes of writes.
- `/etc/cron.d/pg-backup` runs `pg-backup` at 02:30: full backup on Sundays, differential the other days, then `pgbackrest check`. Keeps 2 full backups, so any minute of the last 1-2 weeks can be restored. Log: `/var/log/pg-backup.log`.
- If the Storage Box is unreachable, WAL queues on t4a up to 4 GB and is then dropped (`archive-push-queue-max`) rather than filling the disk. Point-in-time recovery is broken from then until the next full backup; `pgbackrest info` and the heartbeat show it.
- State: `ssh t4a 'cd /srv/postgres && docker compose exec -u postgres postgres pgbackrest --stanza=main info'`

**2. restic, nightly dumps and files** (repo `restic/t4a-production`, `/root/.restic-password`)
- `/etc/cron.d/t4a-backup` runs `t4a-backup` at 04:00 (after rokomet's 03:30 `app.db` copy): `pg_dump` of every database to `/var/backups/postgres`, then restic of those dumps, `/srv` (every `.env`, compose file, cert, `pgbackrest-ssh`), `/etc/cron.d` and `/usr/local/bin`. Keeps 7 daily, 4 weekly, 6 monthly; Sundays reads back 5 %. Log: `/var/log/t4a-backup.log`.

**Keep copies outside t4a** of `/root/.restic-password` and `PGBACKREST_REPO1_CIPHER_PASS` from `/srv/postgres/.env` (password manager). Without them neither backup can be read.

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
