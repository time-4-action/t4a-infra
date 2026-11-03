#!/bin/sh
# Create a database user for one app, with readWrite on its own database only, and print its MONGODB_URI.
# Run on t4a as root: sh /srv/mongo/new-app-mongo.sh <name> [<database>]
# The database defaults to <name>; pass the one the app already uses on t2 when moving it.
set -eu
name="$1"
db="${2:-$1}"
pass=$(openssl rand -hex 24)
cd /srv/mongo
# --eval, not a heredoc: piped input makes mongosh print its prompt ("test> ") in front of the next line of
# output, and an error (user exists) exits non-zero here instead of being printed and ignored.
docker compose exec -T mongo sh -c 'mongosh --quiet -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --eval "$1"' _ \
  "db.getSiblingDB('$db').createUser({ user: '$name', pwd: '$pass', roles: [{ role: 'readWrite', db: '$db' }] })" >/dev/null
echo "MONGODB_URI=mongodb://$name:$pass@mongo:27017/$db?authSource=$db"
