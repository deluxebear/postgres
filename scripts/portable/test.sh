#!/usr/bin/env bash
# Run the relocated bundle as an ordinary user, with no Nix store available.
set -euo pipefail
bundle=$(cd "${1:?Usage: test.sh <bundle>}" && pwd)
if [[ -e /nix/store ]]; then
  echo 'Portability validation requires a machine/container without /nix/store' >&2
  exit 1
fi
export PATH="$bundle/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PGUSER=portable_admin PGDATABASE=postgres PGHOST=127.0.0.1 PGPORT=55432
test_root=$(mktemp -d /tmp/pg-portable.XXXXXX)
data="$test_root/data"
cleanup() {
  status=$?
  if [[ $status -ne 0 && -f "$data/server.log" ]]; then cat "$data/server.log" >&2; fi
  if [[ -f "$data/postmaster.pid" ]]; then pg_ctl -D "$data" -m immediate -w stop >/dev/null || true; fi
  rm -rf "$test_root"
}
trap cleanup EXIT
psql=(psql -X -v ON_ERROR_STOP=1)
for binary in postgres initdb pg_ctl psql pg_dump pg_restore; do "$binary" --version; done
initdb -D "$data" -U "$PGUSER" --locale=C --encoding=UTF8 -A trust >/dev/null
cp "$bundle/share/supabase-cli/config/postgresql.conf.template" "$data/postgresql.conf"
key_script="$bundle/share/supabase-cli/config/pgsodium_getkey.sh"
cat >> "$data/postgresql.conf" <<EOF
port = $PGPORT
unix_socket_directories = '$test_root'
pgsodium.getkey_script = '$key_script'
vault.getkey_script = '$key_script'
pg_durable.worker_role = '$PGUSER'
pg_durable.database = '$PGDATABASE'
pg_durable.host = '$PGHOST'
EOF
start() { pg_ctl -D "$data" -l "$data/server.log" -w start >/dev/null; }
start
"${psql[@]}" <<'SQL'
SET statement_timeout = '90s';
CREATE EXTENSION pg_duckdb;
CREATE EXTENSION pg_durable;
CREATE TABLE portable_probe (amount integer);
INSERT INTO portable_probe VALUES (19), (23);
SQL
# Check the actual SQL versions against the packaged release manifest.
python3 - "$bundle/portable-release.json" <<'PY'
import json, subprocess, sys
for name, extension in json.load(open(sys.argv[1]))['extensions'].items():
    actual = subprocess.check_output(['psql', '-XAt', '-v', 'ON_ERROR_STOP=1', '-c',
        f"SELECT extversion FROM pg_extension WHERE extname='{name}'"], text=True).strip()
    assert actual == extension['sql_version'], (name, actual, extension['sql_version'])
PY

probe() {
  [[ $("${psql[@]}" -Atq -c 'SET duckdb.force_execution=true; SELECT sum(amount) FROM portable_probe') == 42 ]]
  [[ $("${psql[@]}" -At -c "SELECT r['n']::integer FROM duckdb.query('SELECT count(*) AS n FROM duckdb_extensions() WHERE extension_name=''httpfs'' AND loaded') r") == 1 ]]
}
probe
# Poll readiness in separate transactions; bound both waiting and execution.
ready=false
for _ in {1..90}; do
  if [[ $("${psql[@]}" -At -c 'SELECT df.validate_installation()' 2>/dev/null) == t ]]; then ready=true; break; fi
  sleep 1
done
[[ "$ready" == true ]]
"${psql[@]}" <<'SQL'
SET statement_timeout = '90s';
SELECT df.start(df.sql('SELECT 42 AS answer'), 'portable-runtime-probe') AS instance_id \gset
SELECT df.await_instance(:'instance_id');
SELECT (df.result(:'instance_id')::jsonb->'rows'->0->>'answer' = '42') AS result_ok \gset
\if :result_ok
\else
  \quit 1
\endif
SQL
pg_dump --format=custom -f "$test_root/probe.dump"
createdb restored
pg_restore --exit-on-error -d restored "$test_root/probe.dump"
PGDATABASE=restored probe
pg_ctl -D "$data" -m fast -w stop >/dev/null
start
probe

# Check available predecessor SQL upgrade paths against the new binary.
createdb sql_upgrade
for extension in pg_duckdb; do
  # Select the newest installable predecessor that has an upgrade path.
  previous=$("${psql[@]}" -At -c "
    SELECT p.source FROM pg_extension_update_paths('$extension') p
    JOIN pg_available_extension_versions v ON v.name='$extension' AND v.version=p.source
    JOIN pg_available_extensions a ON a.name='$extension' AND a.default_version=p.target
    WHERE p.path IS NOT NULL AND p.source ~ '^[0-9]+[.][0-9]+[.][0-9]+$'
      AND string_to_array(p.source, '.')::int[] < string_to_array(p.target, '.')::int[]
    ORDER BY string_to_array(p.source, '.')::int[] DESC LIMIT 1")
  if [[ -z "$previous" ]]; then echo "No testable predecessor SQL for $extension" >&2; exit 1; fi
  "${psql[@]}" -d sql_upgrade -v extension="$extension" -v previous="$previous" <<'SQL'
CREATE EXTENSION :"extension" VERSION :'previous';
ALTER EXTENSION :"extension" UPDATE;
SQL
done
[[ $("${psql[@]}" -At -d sql_upgrade -c "SELECT count(*) FROM pg_extension e JOIN pg_available_extensions a ON a.name=e.extname WHERE e.extname='pg_duckdb' AND e.extversion=a.default_version") == 1 ]]
echo 'Portable extension lifecycle checks passed without Nix.'
