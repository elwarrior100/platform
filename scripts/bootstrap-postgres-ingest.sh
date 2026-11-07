#!/usr/bin/env bash
# Cria a base de dados e o utilizador "ingest" no PostgreSQL e o Secret com o endereço de ligação.
# Idempotente. A palavra-passe é aleatória e passa por stdin: nunca aparece em argumentos nem no ecrã.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"

kubectl get ns ingest >/dev/null 2>&1 || kubectl create ns ingest
if kubectl -n ingest get secret ingest-db >/dev/null 2>&1; then
  echo "secret ingest-db já existe"
  exit 0
fi

PW="$(openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-24)"
# A palavra-passe e o SQL viajam por stdin (1.ª linha = palavra-passe); nada passa por argumentos.
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
echo "base de dados e secret ingest-db criados"
