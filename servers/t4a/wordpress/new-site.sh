#!/bin/sh
# Create one WordPress site: its database and user in MariaDB, /srv/wordpress/<site>/ from
# _template, and a running container behind Traefik for the given domains.
# Run on t4a as root: sh /srv/wordpress/new-site.sh <site> <domain> [<domain> ...]
# e.g. sh /srv/wordpress/new-site.sh chase the-chase-project.com www.the-chase-project.com
set -eu
[ $# -ge 2 ] || { echo "usage: $0 <site> <domain> [<domain> ...]"; exit 1; }
site="$1"; shift
echo "$site" | grep -Eq '^[a-z0-9][a-z0-9-]{0,30}$' || { echo "site: lowercase letters, digits and - only"; exit 1; }
dir=/srv/wordpress/$site
[ ! -e "$dir" ] || { echo "$dir already exists"; exit 1; }

db=wp_$(echo "$site" | tr - _)
pass=$(openssl rand -hex 24)
rule=""
for d in "$@"; do rule="${rule:+$rule || }Host(\`$d\`)"; done

cd /srv/mariadb
docker compose exec -T mariadb sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"' <<EOF
CREATE DATABASE \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$db'@'%' IDENTIFIED BY '$pass' WITH MAX_USER_CONNECTIONS 20;
GRANT ALL PRIVILEGES ON \`$db\`.* TO '$db'@'%';
EOF

mkdir -p "$dir/html"
cp /srv/wordpress/_template/compose.yml /srv/wordpress/_template/php.ini "$dir/"
chown 33:33 "$dir/html"
umask 077
cat > "$dir/.env" <<EOF
SITE=$site
TRAEFIK_RULE=$rule
WORDPRESS_DB_NAME=$db
WORDPRESS_DB_USER=$db
WORDPRESS_DB_PASSWORD=$pass
EOF

cd "$dir" && docker compose up -d
echo
echo "Site $site is running for: $*"
echo "Next: Cloudflare DNS A record(s) -> 77.42.42.60, proxied; for a new zone also an origin"
echo "certificate in /srv/edge/certs (README). Then open https://$1/wp-admin/install.php"
