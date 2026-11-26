#!/usr/bin/env bash
# CREATE EXTENSION can complete before the asynchronous control worker is ready.
wait_for_durable_control() {
  local provider_schema ready
  provider_schema=$(psql -XAt -v ON_ERROR_STOP=1 -c 'SELECT df.duroxide_schema()')
  case "$provider_schema" in
    duroxide|_duroxide) ;;
    *) echo "Unexpected durable provider schema: $provider_schema" >&2; return 1 ;;
  esac
  for _ in {1..90}; do
    ready=$(psql -XAt -v ON_ERROR_STOP=1 -c "SELECT to_regclass('$provider_schema._worker_ready') IS NOT NULL")
    if [[ "$ready" == t ]] &&
       [[ $(psql -XAt -v ON_ERROR_STOP=1 -c "SELECT EXISTS(SELECT 1 FROM $provider_schema._worker_ready WHERE schema_version >= 1)") == t ]]; then
      return 0
    fi
    sleep 1
  done
  echo 'Durable control worker did not become ready' >&2
  return 1
}
