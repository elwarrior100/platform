#!/usr/bin/env bash
# Creates the "ingest" database and user in PostgreSQL and the Secret with the connection URL.
# Idempotent. The password is random and goes through stdin: never in arguments nor on screen.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"

kubectl get ns ingest >/dev/null 2>&1 || kubectl create ns ingest
if kubectl -n ingest get secret ingest-db >/dev/null 2>&1; then
  echo "secret ingest-db already exists"
  exit 0
fi

PW="$(openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-24)"
# Password and SQL travel through stdin (first line = password); nothing goes through arguments.
{
  printf '%s\n' "$PW"
  cat <<'SQL'
SELECT format('CREATE ROLE ingest LOGIN PASSWORD %L', :'pw') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ingest') \gexec
SELECT format('ALTER ROLE ingest PASSWORD %L', :'pw') \gexec
SELECT 'CREATE DATABASE ingest OWNER ingest' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ingest') \gexec
SQL
} | kubectl -n data exec -i postgres-0 -- sh -c 'read PW; psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres -v pw="$PW" -f -'
kubectl -n ingest create secret generic ingest-db \
  --from-literal=DATABASE_URL="postgresql://ingest:${PW}@postgres.data.svc.cluster.local:5432/ingest?connect_timeout=3"
echo "database and secret ingest-db created"
