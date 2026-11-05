#!/bin/bash
# Compare a WordPress database on t2 and t4a: row count and a hash of every column of every table.
# Run from your machine (ssh aliases t4a-t2 and t4a). See wordpress-cutover.md.
# usage: bash servers/t2/wordpress-db-check.sh wp_<site> [table ...]
set -euo pipefail
db=$1; shift
quiet() { grep -v -E 'post-quantum|store now|upgraded' || true; }
t2() { ssh -o BatchMode=yes t4a-t2 "sudo mariadb -N --default-character-set=utf8mb4 $db" 2> >(quiet >&2); }
t4a() { ssh -o BatchMode=yes t4a "cd /srv/mariadb && docker compose exec -T mariadb sh -c 'mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\" --default-character-set=utf8mb4 -N $db'" 2> >(quiet >&2); }

tables="$*"
[ -n "$tables" ] || tables=$(echo "select table_name from information_schema.tables where table_schema=database() order by 1;" | t2)

declare -A cols
while read -r t c; do cols[$t]=$c; done < <(echo "select table_name, group_concat(concat(char(96),column_name,char(96)) order by ordinal_position) from information_schema.columns where table_schema=database() group by table_name;" | t2 | tr '\t' ' ')

sql="set session group_concat_max_len=1073741824;"
for t in $tables; do
  sql+=" select '$t', count(*), md5(group_concat(md5(concat_ws('|',${cols[$t]})) order by 1 separator '')) from \`$t\`;"
done
dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
echo "$sql" | t2 > "$dir/t2"
echo "$sql" | t4a > "$dir/t4a"
if diff "$dir/t2" "$dir/t4a"; then
  echo "$db: $(wc -l < "$dir/t2") tables, $(awk '{s+=$2}END{print s}' "$dir/t2") rows, identical on t2 and t4a"
else
  echo "$db: DIFFERENT (above: < t2, > t4a)"; exit 1
fi
