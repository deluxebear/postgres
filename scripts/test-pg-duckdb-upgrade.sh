#!/usr/bin/env bash
# Exercise the SQL upgrade path and a fresh install in a non-public schema.
set -euo pipefail
pg_root=$(realpath "${1:?PostgreSQL package path is required}")
export PATH="$pg_root/bin:$PATH"
PGHOST=$(mktemp -d)
export PGHOST PGDATABASE=postgres
data="$PGHOST/data"
cleanup() {
  if [[ -f "$data/postmaster.pid" ]]; then pg_ctl -D "$data" -m immediate -w stop >/dev/null; fi
  rm -rf "$PGHOST"
}
trap cleanup EXIT
initdb -D "$data" --locale=C --encoding=UTF8 -A trust >/dev/null
pg_ctl -D "$data" -l "$data/server.log" -o "-k $PGHOST -c listen_addresses='' -c shared_preload_libraries=pg_duckdb" -w start || {
  cat "$data/server.log" >&2
  exit 1
}
psql -X -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION pg_duckdb WITH SCHEMA public VERSION '1.1.0';
CREATE TABLE invoice(amount integer);
INSERT INTO invoice VALUES (19), (23);
ALTER EXTENSION pg_duckdb UPDATE TO '1.2.2';
SQL
pg_dump --format=custom -f "$PGHOST/upgraded.dump" postgres
createdb restored
pg_restore --exit-on-error -d restored "$PGHOST/upgraded.dump"
for db in postgres restored; do
  [[ $(psql -XAtq -v ON_ERROR_STOP=1 -d "$db" -c "SET duckdb.force_execution=true; SELECT sum(amount) FROM invoice") == 42 ]]
done

createdb fresh
psql -X -v ON_ERROR_STOP=1 -d fresh <<'SQL'
CREATE SCHEMA extensions;
CREATE EXTENSION pg_duckdb WITH SCHEMA extensions;
SELECT 'extensions.read_vortex(text)'::regprocedure;
SQL
for db in postgres fresh restored; do
  [[ $(psql -XAt -v ON_ERROR_STOP=1 -d "$db" -c "SELECT extversion FROM pg_extension WHERE extname='pg_duckdb'") == 1.2.2 ]]
  [[ $(psql -XAt -v ON_ERROR_STOP=1 -d "$db" -c "SELECT r['v']::text FROM duckdb.query('SELECT version() AS v') r") == v2.0.1 ]]
  [[ $(psql -XAt -v ON_ERROR_STOP=1 -d "$db" -c "SELECT r['n']::integer FROM duckdb.query('SELECT count(*) AS n FROM duckdb_extensions() WHERE extension_name=''httpfs'' AND loaded') r") == 1 ]]
done
