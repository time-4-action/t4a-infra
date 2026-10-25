#!/bin/sh
# Create a database and an owner role for one app, and print its DATABASE_URL.
# Run on t4a as root: sh /srv/postgres/new-app-db.sh <name>
# The connection limit keeps one app from using up max_connections for the others.
set -eu
name="$1"
pass=$(openssl rand -hex 24)
cd /srv/postgres
docker compose exec -T postgres psql -U postgres -v ON_ERROR_STOP=1 <<EOF
CREATE ROLE "$name" LOGIN PASSWORD '$pass' CONNECTION LIMIT 30;
CREATE DATABASE "$name" OWNER "$name";
REVOKE ALL ON DATABASE "$name" FROM PUBLIC;
-- PgHero (/srv/pghero) reads statistics only; add the database to its pghero.yml too.
GRANT CONNECT ON DATABASE "$name" TO pghero;
\\c "$name"
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
EOF
echo "DATABASE_URL=postgres://$name:$pass@postgres:5432/$name"
