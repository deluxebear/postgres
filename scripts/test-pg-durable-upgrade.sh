#!/usr/bin/env bash
# Validate the packaged SQL lifecycle on the exact PostgreSQL flavor built by CI.
set -euo pipefail

pg_root=$(realpath "${1:?Usage: test-pg-durable-upgrade.sh <postgres-package> <17|orioledb-17>}")
flavor=${2:?PostgreSQL flavor is required}
export PATH="$pg_root/bin:$PATH"
PGUSER=$(whoami)
export PGHOST=127.0.0.1 PGPORT=55439 PGUSER PGDATABASE=postgres
test_root=$(mktemp -d)
data=''
cleanup() {
  local rc=$?
  if [[ "$rc" -ne 0 && -n "$data" && -f "$data/server.log" ]]; then
    tail -100 "$data/server.log"
  fi
  if [[ -n "$data" && -f "$data/postmaster.pid" ]]; then
    pg_ctl -D "$data" -m immediate -w stop || true
  fi
  rm -rf "$test_root"
}
trap cleanup EXIT

case "$flavor" in
  17) preload=pg_durable ;;
  orioledb-17) preload=orioledb,pg_durable ;;
  *) echo "Unsupported PostgreSQL flavor: $flavor" >&2; exit 1 ;;
esac

for scenario in fresh upgrade; do
  data="$test_root/$scenario"
  initdb -D "$data" --locale=C -A trust >/dev/null
  cat >> "$data/postgresql.conf" <<EOF
port = $PGPORT
listen_addresses = '$PGHOST'
unix_socket_directories = '$test_root'
shared_preload_libraries = '$preload'
pg_durable.worker_role = '$PGUSER'
pg_durable.database = '$PGDATABASE'
pg_durable.host = '$PGHOST'
EOF
  if [[ "$flavor" == orioledb-17 ]]; then
    echo "default_table_access_method = 'orioledb'" >> "$data/postgresql.conf"
  fi
  pg_ctl -D "$data" -l "$data/server.log" -w start >/dev/null
  if [[ "$flavor" == orioledb-17 ]]; then
    psql -X -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION orioledb'
  fi

  if [[ "$scenario" == upgrade ]]; then
    # Reconstruct the predecessor SQL schema using the shipped fixture and
    # immutable upgrade chain. This checks SQL migration, not old-binary replay.
    psql -X -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION pg_durable VERSION '0.2.2';
ALTER EXTENSION pg_durable UPDATE TO '0.2.8';
CREATE TABLE public.durable_upgrade_probe AS
SELECT oid FROM pg_proc WHERE oid = 'df.sql(text)'::regprocedure;
ALTER EXTENSION pg_durable UPDATE;
DO $$ BEGIN
  IF (SELECT oid FROM public.durable_upgrade_probe) <> 'df.sql(text)'::regprocedure THEN
    RAISE EXCEPTION 'Upgrade changed the existing df.sql OID';
  END IF;
END $$;
SQL
  else
    psql -X -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION pg_durable'
  fi

  # Poll in separate transactions: an OrioleDB transaction keeps its snapshot
  # and cannot observe the worker's readiness commit from a long-running DO.
  dx_schema=$(psql -XAt -v ON_ERROR_STOP=1 -c 'SELECT df.duroxide_schema()')
  case "$dx_schema" in
    duroxide|_duroxide) ;;
    *) echo "Unexpected provider schema: $dx_schema" >&2; exit 1 ;;
  esac
  ready=false
  for _ in {1..60}; do
    if [[ $(psql -XAt -v ON_ERROR_STOP=1 -c "SELECT to_regclass('$dx_schema._worker_ready') IS NOT NULL") == t ]] &&
       [[ $(psql -XAt -v ON_ERROR_STOP=1 -c "SELECT EXISTS(SELECT 1 FROM $dx_schema._worker_ready WHERE schema_version >= 2)") == t ]]; then
      ready=true
      break
    fi
    sleep 0.5
  done
  if [[ "$ready" != true ]]; then echo 'Control runtime not ready' >&2; exit 1; fi

  psql -X -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
  IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_durable') <>
     (SELECT default_version FROM pg_available_extensions WHERE name = 'pg_durable') THEN
    RAISE EXCEPTION 'Extension version does not match the packaged version';
  END IF;
  IF current_setting('pg_durable.http_security') <> 'restricted' THEN
    RAISE EXCEPTION 'Unexpected default HTTP policy';
  END IF;
  IF NOT df.validate_installation() THEN RAISE EXCEPTION 'Invalid installation'; END IF;
END $$;
CREATE ROLE durable_test_user LOGIN;
SELECT df.grant_usage('durable_test_user', include_http => true);
SET ROLE durable_test_user;
DO $$ BEGIN
  IF df.with_http_options(df.http('https://api.github.com'::text), '{}'::jsonb) IS NULL THEN
    RAISE EXCEPTION 'HTTP options constructor failed';
  END IF;
  IF df.endpoint('test_endpoint', '/test') IS NULL THEN RAISE EXCEPTION 'Endpoint constructor failed'; END IF;
END $$;
SELECT df.start(df.sql('SELECT 42 AS answer'), 'ci-lifecycle-probe') AS instance_id \gset
SELECT df.await_instance(:'instance_id');
SELECT (df.result(:'instance_id')::jsonb->'rows'->0->>'answer' = '42') AS result_ok \gset
\if :result_ok
\else
\quit 1
\endif
SQL
  pg_ctl -D "$data" -m fast -w stop >/dev/null
  echo "pg_durable $flavor $scenario lifecycle passed"
done
