#!/usr/bin/env bash
# Prepares the database and installs (or upgrades) Airflow. Idempotent. Secrets come from the vault (ADR-011).
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

kubectl apply -f "$ROOT/platform/k8s/airflow/logs-pvc.yaml" >/dev/null

helm repo add apache-airflow https://airflow.apache.org >/dev/null 2>&1 || true
helm repo update apache-airflow >/dev/null

PWFILE="$(mktemp)"; trap 'rm -f "$PWFILE"' EXIT
umask 077; kubectl -n "$NS" get secret airflow-admin -o jsonpath='{.data.password}' | base64 -d > "$PWFILE"
helm upgrade --install airflow apache-airflow/airflow --version "$CHART_VERSION" -n "$NS" \
  -f "$ROOT/platform/airflow/values.yaml" --set-file createUserJob.defaultUser.password="$PWFILE" \
  --timeout 15m
