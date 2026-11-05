# WordPress cutover: t2 → t4a

Moving the two WordPress sites from t2 (nginx + PHP-FPM + MariaDB 10.5) to t4a (one Apache container per
site, MariaDB 11.4, Traefik). `patrik-test` is not moved: decided 2026-11-05 to drop it (no vhost, its
database is at IONOS). Its files stay on t2 until t2 is retired.

| Site | Domains (Cloudflare zone) | t2 | t4a |
|---|---|---|---|
| `patrik-web` | `patrik-web.time-4-action.com` (`time-4-action.com`) | `/mnt/vdc/www/t4a/patrik-web`, `wp_patrik_web` | `/srv/wordpress/patrik-web`, `wp_patrik_web` |
| `the-chase-project` | `www.the-chase-project.com`, `the-chase-project.com` (`the-chase-project.com`) | `/mnt/vdc/www/t4a/the-chase-project`, `wp_the_chase_project` | `/srv/wordpress/the-chase-project`, `wp_the_chase_project` |

| Step | State |
|---|---|
| 1. Sites created on t4a, files and databases copied, checked | done 2026-11-05 |
| 2. Final sync (only if something changed on t2 since step 1) | at cutover |
| 3. DNS to t4a | at cutover |
| 4. After: monitoring, t2 sites stopped | after cutover |

## 1. Copy (done 2026-11-05)

Everything is streamed t2 → your machine → t4a; nothing is staged on t2 (`/data` is full).

- `sh /srv/wordpress/new-site.sh patrik-web patrik-web.time-4-action.com` and
  `sh /srv/wordpress/new-site.sh the-chase-project the-chase-project.com www.the-chase-project.com`,
  then `docker compose down` in each folder and emptied `html/` (the fresh WordPress the image put there).
- Files, with `tar` over two ssh pipes. Not copied from `patrik-web`: `db577760631_2024-05-20.dump`,
  `phpinfo.php`, `wp-config_1.php`, `wp-config_2.php`, `liesmich.html`. Files on t4a = t2 minus those
  5 (23 279 and 4 363).
- Databases: `mariadb-dump --single-transaction --quick --default-character-set=utf8mb4` on t2, piped
  into `wp_<site>` on t4a. `wp_patrik_web` has 3 `latin1_german2_ci` tables next to `utf8` ones; the
  check below covers them. Checked with [`wordpress-db-check.sh`](wordpress-db-check.sh): row count
  and a hash of every column of every table are identical on both servers (12 and 58 tables).
- Each site keeps its own `wp-config.php` (salts and table prefix unchanged, so logins survive).
  Changed: `DB_HOST` `mariadb`, `DB_USER` / `DB_PASSWORD` read with `getenv()` from the site's `.env`,
  and the two lines the t4a template adds (HTTPS from `X-Forwarded-Proto`, `DISALLOW_FILE_EDIT`).
- `patrik-web/.htaccess`: only the standard WordPress rules. The old file had ~60 redirects to
  patrikinternational.com (`^team`, `^wing`, `^down`, ...) that nginx on t2 never applied; Apache
  would have, and `^down` would have caught `/downloads/`. The original is
  `/srv/wordpress/patrik-web/htaccess.t2-original`.
- The `the-chase-project.com` origin cert (to 2041) is in `/srv/edge/certs/the-chase-project.com`
  and `edge/dynamic/tls.yml`.

Checked by requesting the same paths from live t2 and from the t4a containers (inside t4a, with the
headers Traefik sends; t4a itself only answers Cloudflare): 60 `patrik-web` and 51
`the-chase-project` paths (pages, posts, archives, feeds, login, uploads, theme files) give the same
status and title. Differences, all on purpose:

- `the-chase-project` `/favicon.ico`: 200 on t4a, 404 on t2. Its `.htaccess` favicon rules now apply.
- `patrik-web` loads the WPML language switcher's CSS/JS from its own domain on t4a; on t2 it loads
  them from `patrik-windsurf.com`, which redirects away, so they are broken on t2 today.
- `readme.html`, `license.txt`, `wp-config.php`, dotfiles and PHP in `uploads/` are 403
  (`wordpress/apache.conf`, as nginx did on t2).

## 2. Final sync (at cutover, only if t2 changed)

Ask whoever edits the sites not to, from the copy until DNS is switched. If a site changed anyway,
copy it again right before step 3. Never copy `wp-config.php` or `.htaccess` again: t4a's are edited.

```sh
site=the-chase-project   # or patrik-web
ssh t4a-t2 "sudo tar -C /mnt/vdc/www/t4a/$site --exclude=./wp-config.php --exclude=./.htaccess \
  --exclude=./db577760631_2024-05-20.dump --exclude=./phpinfo.php --exclude=./wp-config_1.php \
  --exclude=./wp-config_2.php --exclude=./liesmich.html -cf - ." \
  | ssh t4a "tar -C /srv/wordpress/$site/html -xf - --no-same-owner && chown -R 33:33 /srv/wordpress/$site/html"

db=wp_$(echo $site | tr - _)     # the dump drops and recreates each table
ssh t4a-t2 "sudo mariadb-dump --single-transaction --quick --default-character-set=utf8mb4 --no-tablespaces $db | gzip -1" \
  | ssh t4a "gunzip | (cd /srv/mariadb && docker compose exec -T mariadb sh -c 'mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\" --default-character-set=utf8mb4 $db')"
bash servers/t2/wordpress-db-check.sh $db
```

The check compares every table, so run it right after the import. Once the t4a site serves
requests, `*_options` drifts (transients, cron) and only the content tables (posts, postmeta,
terms, users, comments) stay comparable: pass them as extra arguments.

## 3. DNS

The records are proxied, so the switch takes effect in seconds (TTL does not matter). In Cloudflare
(`cf` CLI), one site at a time:

- `time-4-action.com` zone: A `patrik-web` → `77.42.42.60`, proxied.
- `the-chase-project.com` zone: A `@` and A `www` (or the CNAME `www` points at `@`) → `77.42.42.60`, proxied.

Then check in a browser: home page, a post, an image, `/wp-admin/` login, and (patrik-web) the
language switcher. `docker compose logs -f wordpress` in the site's folder shows the requests.

**Rollback**: point the same records back at `194.28.111.245`. t2 is untouched until step 4.

## 4. After

- Add both URLs to `servers/t4a/monitoring/targets/sites.yml`.
- `patrik-web`: check WPML still shows its licence as registered (it is tied to the domain, which
  does not change).
- `the-chase-project`: update core (6.7.2) and plugins from wp-admin; the STRATO leftovers
  (`strato-assistant`, mu-plugin `automation-by-installatron.php`) can be removed.
- On t2, after a few days without problems: disable the two nginx vhosts and `systemctl reload nginx`
  (do not delete the files; t2's restic backup keeps running until t2 is retired).
