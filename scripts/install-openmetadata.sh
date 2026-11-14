#!/usr/bin/env bash
# Prepares the database and secrets and installs (or upgrades) OpenMetadata. Idempotent.
# No password goes through arguments or appears on screen. See modbus_data_plataform docs/adr/009.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"
NS=openmetadata
VERSION=2.0.7
VM="${LIMA_INSTANCE:-industrial}"

rand() { openssl rand -base64 36 | tr -d '/+=\n' | cut -c1-32; }
secret_exists() { kubectl -n "$NS" get secret "$1" >/dev/null 2>&1; }

# OpenSearch refuses to start with a low vm.max_map_count (persisted in /etc/sysctl.d; rerunning the script is safe)
limactl shell "$VM" -- sudo sysctl -w vm.max_map_count=262144 >/dev/null
limactl shell "$VM" -- sh -c 'echo "vm.max_map_count=262144" | sudo tee /etc/sysctl.d/99-opensearch.conf >/dev/null'

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

if ! secret_exists openmetadata-db; then
  PW="$(rand)"
  {
    printf '%s\n' "$PW"
    cat <<'SQL'
SELECT format('CREATE ROLE openmetadata LOGIN PASSWORD %L', :'pw') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'openmetadata') \gexec
SELECT format('ALTER ROLE openmetadata PASSWORD %L', :'pw') \gexec
SELECT 'CREATE DATABASE openmetadata OWNER openmetadata' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'openmetadata') \gexec
SQL
  } | kubectl -n data exec -i postgres-0 -- sh -c 'read PW; psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres -v pw="$PW" -f -'
  kubectl -n "$NS" create secret generic openmetadata-db --from-literal=password="$PW"
fi

helm repo add open-metadata https://helm.open-metadata.org/ >/dev/null 2>&1 || true
helm repo update open-metadata >/dev/null
helm upgrade --install openmetadata-dependencies open-metadata/openmetadata-dependencies \
  --version "$VERSION" -n "$NS" -f "$ROOT/platform/openmetadata/values-dependencies.yaml" --wait --timeout 10m
helm upgrade --install openmetadata open-metadata/openmetadata \
  --version "$VERSION" -n "$NS" -f "$ROOT/platform/openmetadata/values.yaml" --wait --timeout 15m
kubectl -n "$NS" get pods
