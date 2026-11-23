#!/usr/bin/env bash
# Makes sure the "ingest" database and user exist in PostgreSQL, with the password from the vault.
# The Secret ingest/ingest-db itself comes from the External Secrets Operator. Idempotent; nothing is printed.
#
# Live path (modbus ADR-022, L1): also the TimescaleDB extension in "ingest" (creating it needs the superuser), the
# schema "live" owned by ingest (the collector fills it: a trigger on the spool copies each sample to a hypertable),
# and the read-only role grafana_live, which may only read that schema (never the spool itself).
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"
show_target

wait_secret ingest ingest-db
secret_value ingest ingest-db DATABASE_URL | url_password | ensure_pg_role ingest ingest

kubectl -n data exec -i postgres-0 -- psql -v ON_ERROR_STOP=1 -q -U postgres -d ingest <<'SQL'
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE SCHEMA IF NOT EXISTS live AUTHORIZATION ingest;
SQL

wait_secret monitoring grafana-live
secret_value monitoring grafana-live GRAFANA_LIVE_PASSWORD | {
  IFS= read -r pw || true
  printf '%s\n' "$pw"
  cat <<'SQL'
SELECT format('CREATE ROLE grafana_live LOGIN PASSWORD %L', :'pw') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'grafana_live') \gexec
SELECT format('ALTER ROLE grafana_live PASSWORD %L', :'pw') \gexec
ALTER ROLE grafana_live SET statement_timeout = '10s';
ALTER ROLE grafana_live CONNECTION LIMIT 5;
GRANT CONNECT ON DATABASE ingest TO grafana_live;
GRANT USAGE ON SCHEMA live TO grafana_live;
GRANT SELECT ON ALL TABLES IN SCHEMA live TO grafana_live;
ALTER DEFAULT PRIVILEGES FOR ROLE ingest IN SCHEMA live GRANT SELECT ON TABLES TO grafana_live;
SQL
} | kubectl -n data exec -i postgres-0 -- sh -c 'read PW; psql -v ON_ERROR_STOP=1 -q -U postgres -d ingest -v pw="$PW" -f -'
echo "database and user ingest ready (with the live schema and the grafana_live reader)"
