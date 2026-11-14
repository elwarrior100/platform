#!/usr/bin/env bash
# Prepares the Airflow database role (idempotent). Airflow itself is deployed by Argo CD; secrets come from the vault.
# No password goes through arguments or appears on screen.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"
NS=airflow
CHART_VERSION=1.22.0

. "$ROOT/scripts/lib.sh"
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

# Secrets come from the vault through the External Secrets Operator (platform/k8s/secrets/airflow.yaml).
for s in airflow-metadata airflow-fernet airflow-api-secret airflow-jwt airflow-admin lakefs-credentials; do
  wait_secret "$NS" "$s"
done
# Database and user "airflow", with the password inside the metadata connection URL.
secret_value "$NS" airflow-metadata connection | url_password | ensure_pg_role airflow airflow

echo "database ready. Airflow itself is installed and upgraded by Argo CD (platform/argocd/apps/airflow.yaml)."
