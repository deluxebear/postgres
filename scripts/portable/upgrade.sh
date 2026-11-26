#!/usr/bin/env bash
# Upgrade an actual, previously published portable database to the new binary.
set -euo pipefail
current=$(cd "${1:?Current bundle is required}" && pwd)
previous=$(cd "${2:?Previous bundle is required}" && pwd)
export PGHOST=127.0.0.1 PGPORT=55433 PGUSER=portable_admin PGDATABASE=postgres
export PATH="$previous/bin:/usr/bin:/bin:/usr/sbin:/sbin"
root=$(mktemp -d /tmp/pg-upgrade.XXXXXX)
data="$root/data"
cleanup() {
  status=$?
  if [[ $status -ne 0 && -f "$data/server.log" ]]; then cat "$data/server.log" >&2; fi
  if [[ -f "$data/postmaster.pid" ]]; then pg_ctl -D "$data" -m immediate -w stop >/dev/null || true; fi
  rm -rf "$root"
}
trap cleanup EXIT
psql=(psql -X -v ON_ERROR_STOP=1)
initdb -D "$data" -U "$PGUSER" --locale=C --encoding=UTF8 -A trust >/dev/null
cat >> "$data/postgresql.conf" <<EOF
listen_addresses = '$PGHOST'
port = $PGPORT
unix_socket_directories = '$root'
shared_preload_libraries = 'pg_duckdb, pg_durable'
pg_durable.worker_role = '$PGUSER'
pg_durable.database = '$PGDATABASE'
pg_durable.host = '$PGHOST'
EOF
pg_ctl -D "$data" -l "$data/server.log" -w start >/dev/null
"${psql[@]}" <<'SQL'
CREATE EXTENSION pg_duckdb;
CREATE EXTENSION pg_durable;
CREATE ROLE portable_workflow_user LOGIN;
SELECT df.grant_usage('portable_workflow_user');
CREATE TABLE upgrade_probe (amount int);
INSERT INTO upgrade_probe VALUES (19), (23);
SET statement_timeout = '90s';
CREATE TABLE completed_workflow (id text);
GRANT SELECT ON completed_workflow TO portable_workflow_user;
SET ROLE portable_workflow_user;
SELECT df.start(df.sql('SELECT 42 AS answer'), 'previous-portable-probe') AS instance_id \gset
SELECT df.await_instance(:'instance_id');
RESET ROLE;
INSERT INTO completed_workflow VALUES (:'instance_id');
SQL
pg_ctl -D "$data" -m fast -w stop >/dev/null
export PATH="$current/bin:/usr/bin:/bin:/usr/sbin:/sbin"
pg_ctl -D "$data" -l "$data/server.log" -w start >/dev/null
"${psql[@]}" <<'SQL'
ALTER EXTENSION pg_duckdb UPDATE;
ALTER EXTENSION pg_durable UPDATE;
SQL
[[ $("${psql[@]}" -Atq -c 'SET duckdb.force_execution=true; SELECT sum(amount) FROM upgrade_probe') == 42 ]]
[[ $("${psql[@]}" -Atq -c "SET ROLE portable_workflow_user; SELECT df.result(id)::jsonb->'rows'->0->>'answer' FROM completed_workflow") == 42 ]]
"${psql[@]}" <<'SQL'
SET statement_timeout = '90s';
SET ROLE portable_workflow_user;
SELECT df.start(df.sql('SELECT 43 AS answer'), 'upgraded-portable-probe') AS instance_id \gset
SELECT df.await_instance(:'instance_id');
SELECT (df.result(:'instance_id')::jsonb->'rows'->0->>'answer' = '43') AS result_ok \gset
\if :result_ok
\else
  \quit 1
\endif
SQL
python3 - "$current/portable-release.json" <<'PY'
import json, subprocess, sys
for name, extension in json.load(open(sys.argv[1]))['extensions'].items():
    version = subprocess.check_output(['psql', '-XAt', '-v', 'ON_ERROR_STOP=1', '-c',
        f"SELECT extversion FROM pg_extension WHERE extname='{name}'"], text=True).strip()
    assert version == extension['sql_version'], (name, version, extension['sql_version'])
PY
echo 'Real predecessor binary upgrade passed.'
