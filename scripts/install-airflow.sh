#!/usr/bin/env bash
# Prepara os segredos e a base de dados, e instala (ou atualiza) o Airflow. Idempotente.
# Nenhuma palavra-passe passa por argumentos nem aparece no ecrã.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"
NS=airflow
CHART_VERSION=1.22.0

rand() { openssl rand -base64 36 | tr -d '/+=\n' | cut -c1-32; }
secret_exists() { kubectl -n "$NS" get secret "$1" >/dev/null 2>&1; }

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

if ! secret_exists airflow-metadata; then
  PW="$(rand)"
  {
    printf '%s\n' "$PW"
    cat <<'SQL'
SELECT format('CREATE ROLE airflow LOGIN PASSWORD %L', :'pw') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'airflow') \gexec
SELECT format('ALTER ROLE airflow PASSWORD %L', :'pw') \gexec
SELECT 'CREATE DATABASE airflow OWNER airflow' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'airflow') \gexec
SQL
  } | kubectl -n data exec -i postgres-0 -- sh -c 'read PW; psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres -v pw="$PW" -f -'
  kubectl -n "$NS" create secret generic airflow-metadata \
    --from-literal=connection="postgresql+psycopg2://airflow:${PW}@postgres.data.svc.cluster.local:5432/airflow"
fi
secret_exists airflow-fernet || kubectl -n "$NS" create secret generic airflow-fernet \
  --from-literal=fernet-key="$(openssl rand -base64 32 | tr '+/' '-_')"
secret_exists airflow-api-secret || kubectl -n "$NS" create secret generic airflow-api-secret --from-literal=api-secret-key="$(rand)"
secret_exists airflow-jwt || kubectl -n "$NS" create secret generic airflow-jwt --from-literal=jwt-secret="$(rand)"
secret_exists airflow-admin || kubectl -n "$NS" create secret generic airflow-admin --from-literal=password="$(rand)"

# credenciais do lakeFS: copiadas do namespace ingest (nunca passam pelo ecrã)
secret_exists lakefs-credentials || kubectl -n ingest get secret lakefs-credentials -o json \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps({"apiVersion":"v1","kind":"Secret","metadata":{"name":"lakefs-credentials","namespace":"airflow"},"data":d["data"]}))' \
  | kubectl apply -f - >/dev/null

kubectl apply -f "$ROOT/platform/k8s/airflow/logs-pvc.yaml" >/dev/null

helm repo add apache-airflow https://airflow.apache.org >/dev/null 2>&1 || true
helm repo update apache-airflow >/dev/null

PWFILE="$(mktemp)"; trap 'rm -f "$PWFILE"' EXIT
umask 077; kubectl -n "$NS" get secret airflow-admin -o jsonpath='{.data.password}' | base64 -d > "$PWFILE"
helm upgrade --install airflow apache-airflow/airflow --version "$CHART_VERSION" -n "$NS" \
  -f "$ROOT/platform/airflow/values.yaml" --set-file createUserJob.defaultUser.password="$PWFILE" \
  --timeout 15m
