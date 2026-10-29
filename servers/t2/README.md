# t2 (T-2, `194.28.111.245`, AlmaLinux 9)

Reached as `almalinux` with sudo: `ssh t4a-t2`. Its other configs live in time-4-action/t4a-ops
(`/root/t4a-ops` on the server); alerts and the nightly cleanup are in `servers/alerts`.

## Docker daemon

`daemon.json` is installed as `/etc/docker/daemon.json`:

- `data-root` on the `/data` disk.
- Container logs capped at 3 files of 10 MB. This applies only to containers created
  after it was set (2026-10-28): app containers get it on their next deploy, others when
  they are recreated. Before it, `t4a-mk-automation` had a 308 MB log; that log is kept
  in `/data/log-archive/`.
- `live-restore`: containers keep running while Docker itself restarts, so a change
  here needs no downtime.

To change it:
```
scp daemon.json t4a-t2:/tmp/ && ssh t4a-t2 'sudo dockerd --validate --config-file /tmp/daemon.json \
  && sudo install -m 644 /tmp/daemon.json /etc/docker/daemon.json && sudo systemctl restart docker'
```

## Monitoring (`monitoring/` → `/data/stack/monitoring`)

Grafana Alloy sends t2's host metrics, every container's metrics and every container's logs to
Prometheus and Loki on t4a (`servers/t4a/README.md`, "Monitoring"), through
https://ingest.time-4-action.com with basic auth `t2`. Its config is the shared
`servers/t4a/monitoring/alloy/config.alloy`; `compose.yml` here sets `SERVER=t2` and the URLs.
`/data/stack/monitoring/.env` (mode 600, not in git) holds `INGEST_PASSWORD`, the same as
`/root/ingest-login` on t4a. About 3 % CPU and 230 MB RAM (limit 384 MB).

Deploy or update (from the repo root):
```
scp servers/t2/monitoring/compose.yml servers/t4a/monitoring/alloy/config.alloy t4a-t2:/tmp/
ssh t4a-t2 'sudo install -m 644 /tmp/compose.yml /tmp/config.alloy /data/stack/monitoring/ \
  && cd /data/stack/monitoring && sudo docker compose up -d && sudo docker compose restart alloy'
```
If it stops, Grafana alerts "Server stopped reporting" for t2 within about 7 minutes.

Beszel and Uptime Kuma still run here; Grafana covers what they show, so they can go when t2 is retired.

## Inventory (checked 2026-10-29)

Everything that runs on t2, for the move to t4a. nginx on 80/443 fronts it all; Cloudflare is in front of nginx
(origin certs in `/etc/cloudflare-origin/{patrik-international,the-chase-project,time-4-action}`).
Docker's published ports are blocked from outside by `t4a-docker-ports.service` (a `DOCKER-USER` iptables chain).

### Docker apps (`/data/stack/apps/...`, one compose project each)

| App | Port | Host | State and notes |
|---|---|---|---|
| recharge-hub (web, worker, migrate) + `recharge-hub-postgres-1` (Postgres 16) | 3192, 5432 (local) | `recharge-hub.` | Postgres data in `recharge-hub/data/postgres` |
| recharge-si (partners integration API) | 4545 | `recharge-sources.` | Uses MongoDB |
| t4a-partner-portal-api | 3001 | `api.`, `export.` | `export/api/data` |
| t4a-partner-portal-ui | 3002 | `b2b.` | `.env`: Gmail app password, Auth0 |
| t4a-admin | 3005 | `admin.` | `.env.local`: Auth0, Mongo, S3, Metakocka |
| t4a-chat-ui | 3003 (host network) | `chat.` | `.env.local`: Anthropic, ElevenLabs, Deepgram, Google, Auth0. Image is `:latest` |
| t4a-mk-automation | 3000 | `mkauto.` | 737 MB in its dir; image has no tag. A copy of `.env` is in `time-4-action/patrik/` |
| t4a-mcp + t4a-chromadb | 8000, 8001 (local) | `mcp.` | `mcp/chroma_db`, `bm25_indexes`, `uploads` (80 MB) |
| patrik-warranty-form | 4000 | `patrik-international.com`, `dev-warranty.`, `warranty-preview.` | Image has no tag. Needs S3, Mongo, Google service account, SMTP, Mapbox, Sentry |
| Uptime Kuma, Beszel | 3333, 8090 | `status.`, `monitor.` | Volume `uptime-kuma` 820 MB. Optional, Grafana replaces them |
| Alloy | none | none | See Monitoring above |

Every `.env` / `.env.local` is in the restic `configs` backup. Copy them over a secure channel, never through git.

### Host services (not in Docker)

- **MariaDB 10.5.29**, datadir `/mnt/vdc/mysql`, only the two WordPress databases below (listens on `*:3306`, firewalld does not open it).
- **MongoDB**, `/data/mongo` (18 MB), auth on, listens on `0.0.0.0:27017`. firewalld allows 27017 only from 176.76.128.14,
  176.76.102.199, 87.119.132.30, 176.76.130.2 and 87.119.143.210, and drops 92.118.39.57. Used by admin, chat, mcp,
  recharge-si and the warranty form. t4a has no Mongo yet.
- **PHP-FPM**: default pool PHP 8.5 (`www.sock`) serves both WordPress sites. A PHP 8.2 `patrik-web` pool (`php82-php-fpm`)
  runs but no vhost uses it.
- **autodiscover.service**: Node app in `/mnt/vdc/www/autodiscover-server`, 127.0.0.1:8443, with `/mnt/vdc/www/mail/config-v1.1.xml`
  (autoconfig). Served on `autodiscover.` and `autoconfig.time-4-action.com`. Mail itself is not on t2
  (MX of time-4-action.com is `mx1.t-2.si`; etiam.si is Google; the-chase-project.com is STRATO).
- **certbot**: root cron 03:00 with Cloudflare DNS credentials in `/data/certbot/credentials/` (two accounts: `cloudflare.ini`,
  `cloudflare-t4a.ini`). Wildcard cert `etiam.si`, `*.etiam.si`, `*.t4a.etiam.si` valid to 2027-01-12. nginx redirects
  `*.t4a.etiam.si` to https and `*.*.etiam.si` to `export.time-4-action.com`. The `the-chase-project` cert expired 2026-07-15 and is unused.
- **Backups**: restic to the Storage Box (`restic/t4a-t2`, never touch it), daily 03:00: tags `mariadb`, `wordpress`
  (`/mnt/vdc/www/t4a`), `configs`, `hub-postgres`, `mongodb`. Keep 7 daily, 4 weekly, 6 monthly.
- Static site `time-4-action.com` / `www`: one `index.html` in `/mnt/vdc/www/t4a/time-4-action`.

### WordPress (not Multisite, three installs in `/mnt/vdc/www/t4a/`)

| Site | URL | Core | Theme | Database (prefix) | Size |
|---|---|---|---|---|---|
| `patrik-web` | `patrik-web.time-4-action.com` | 6.9.4 | Enfold | `wp_patrik_web` 113 MB (`wp_`) | 2.8 GB, uploads 2.0 GB |
| `the-chase-project` | `www.the-chase-project.com` (apex redirects to www) | 6.7.2 (outdated), `de_DE` | twentytwentyfive | `wp_the_chase_project` 11 MB (`tgnh_`) | 119 MB |
| `patrik-test` | no vhost | 5.1.15 | Enfold | **remote IONOS database** (`db5002447720.hosting-data.io`), not on t2 | 2.6 GB |

- `patrik-web` plugins: WPML (`sitepress-multilingual-cms`, `wpml-cms-nav`, `wpml-media-translation`; the licence key is tied
  to the domain), antispam-bee, classic-editor, duplicate-post, facebook-page-likebox, tinymce-advanced. Permalinks
  `/blog/%year%/%monthnum%/%day%/%postname%/`. Its docroot also holds a 76 MB `db577760631_2024-05-20.dump`, `phpinfo.php`,
  `wp-config_1.php`, `wp-config_2.php`: not denied by the vhost, so probably downloadable now. Do not copy them.
  `.htaccess` has Apache rules that nginx ignores but t4a's Apache will apply (including a `patrik-windsurf.com` redirect).
- `the-chase-project` plugins: akismet, favicon-by-realfavicongenerator, insta-gallery (Instagram token), limit-login-attempts-reloaded,
  social-icons-widget-by-wpzoom, `strato-assistant` and mu-plugin `automation-by-installatron.php` (STRATO leftovers, can go).
- `patrik-international.com` is not WordPress: it proxies to the warranty form, with a rewrite from
  `/warranty/wp-content/uploads/arforms/userfiles/` to the Hetzner bucket `patrik-assets` (`/archive/warranty/`);
  `assets.patrik-international.com` and `dev-warranty-assets.` proxy the same bucket.
- nginx rules to carry over: deny `wp-config.php`, readme, license, dotfiles (except `.well-known`) and PHP in `uploads/`;
  `expires max` on static files; `client_max_body_size 64M`; `fastcgi_read_timeout 300`; X-Frame-Options, nosniff, Referrer-Policy.
- PHP limits on t2 are 2 MB upload, 8 MB post, 128 MB memory. The t4a template uses 64 / 64 / 256 MB.
- No wp-cli on t2, and `DISABLE_WP_CRON` is not set (WP-cron is traffic-triggered, same as on t4a).

### Leftovers

`/data/stack/apps/mail-migration` (May 2026 imapsync tool, mailbox list, may hold credentials: archive, do not copy blindly),
`/home/almalinux` (`Mail/`, `cleanup.sh`, `docker-migration-2026-04-24.md`), `/data/log-archive`.
`/data` is 81 % full (4 GB free), so do not stage dumps there.

## Moving to t4a

1. **Decide first**: what to do with `patrik-test` and its IONOS database; where MongoDB lives on t4a; which outside hosts
   connect to Mongo (the five IPs above).
2. **Data**: `pg_dump` Recharge Hub; `mongodump` Mongo; `mariadb-dump` the two WP databases; copy ChromaDB, `export/api/data`,
   `mk-automation`, the `.env` files. Do a trial restore on t4a.
3. **WordPress**, per site: `sh /srv/wordpress/new-site.sh <site> <domain>...` on t4a, copy files into `html/` (`chown 33:33`),
   import the dump, point `wp-config.php` at `DB_HOST mariadb` with the user from `.env`, keep the table prefix. Review `.htaccess`.
   Test with a hosts-file override before DNS. Check WPML and Enfold on PHP 8.5.
4. **TLS**: copy the `patrik-international` and `the-chase-project` Cloudflare origin certs to `/srv/edge/certs`.
5. **Apps**: bring up each app on t4a behind Traefik and add its URL to `servers/t4a/monitoring/targets/sites.yml`.
   Move autodiscover/autoconfig, or retire them.
6. **Cutover**: lower DNS TTLs a day ahead, then repoint the A records (proxied) to t4a, site by site. Do not touch MX.
   Decide what happens to the `etiam.si` wildcard redirects and the certbot job.
7. **After**: take a final backup on t2, stop (do not delete) services, keep t2 and its restic repo for a few weeks.
