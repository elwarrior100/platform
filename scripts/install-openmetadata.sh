#!/usr/bin/env bash
# Prepares the OpenMetadata database role and the OpenSearch sysctl (idempotent). OpenMetadata itself is deployed
# by Argo CD; secrets come from the vault.
# No password goes through arguments or appears on screen. See modbus_data_plataform docs/adr/009.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"
NS=openmetadata
VERSION=2.0.7
VM="${LIMA_INSTANCE:-industrial}"

. "$ROOT/scripts/lib.sh"

# OpenSearch refuses to start with a low vm.max_map_count (persisted in /etc/sysctl.d; rerunning the script is safe)
# Only for the local Lima VM; on Oracle envs/oracle/bootstrap-vm.sh already sets it.
if kubectl get nodes -o name | grep -q "lima-$VM"; then
  limactl shell "$VM" -- sudo sysctl -w vm.max_map_count=262144 >/dev/null
  limactl shell "$VM" -- sh -c 'echo "vm.max_map_count=262144" | sudo tee /etc/sysctl.d/99-opensearch.conf >/dev/null'
fi

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

# The password comes from the vault through the External Secrets Operator (platform/k8s/secrets/openmetadata.yaml).
wait_secret "$NS" openmetadata-db
secret_value "$NS" openmetadata-db password | ensure_pg_role openmetadata openmetadata

echo "database ready. OpenMetadata itself is installed and upgraded by Argo CD (platform/argocd/apps/openmetadata*.yaml)."
