#!/usr/bin/env bash
# Prints every container image the platform deploys, one per line, as pinned in git: the image: lines of the plain
# manifests, plus what the Helm charts render with our values (chart versions and values read from platform/argocd/apps
# and platform/*/values*.yaml). Used by the weekly re-scan (.github/workflows/images.yml); needs helm.
# Usage: ./scripts/deployed-images.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
{
  grep -rhoE 'image: *"?[^" ]+' platform/k8s envs projects --include='*.yaml' | sed -E 's/image: *"?//'
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  helm repo add eso https://charts.external-secrets.io >/dev/null 2>&1 || true
  helm repo add pc https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add om https://helm.open-metadata.org/ >/dev/null 2>&1 || true
  helm repo add airflow https://airflow.apache.org >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1
  ver() { grep -A3 "chart: $1\$" "platform/argocd/apps/$2.yaml" | grep -oE 'targetRevision: [0-9.]+' | head -1 | cut -d' ' -f2; }
  python3 -c 'import yaml,sys; print(yaml.safe_dump(yaml.safe_load(open("platform/argocd/apps/external-secrets.yaml"))["spec"]["source"]["helm"]["valuesObject"]))' > "$TMP/eso.yaml"
  helm template x eso/external-secrets --version "$(ver external-secrets external-secrets)" -f "$TMP/eso.yaml"
  helm template x argo/argo-cd --version "$(ver argo-cd argocd)" -f platform/argocd/values.yaml
  helm template x pc/kube-prometheus-stack --version "$(ver kube-prometheus-stack monitoring)" -f platform/monitoring/values.yaml
  helm template x om/openmetadata-dependencies --version "$(ver openmetadata-dependencies openmetadata-dependencies)" -f platform/openmetadata/values-dependencies.yaml
  helm template x om/openmetadata --version "$(ver openmetadata openmetadata)" -f platform/openmetadata/values.yaml
  helm template x airflow/airflow --version "$(ver airflow airflow)" -f platform/airflow/values.yaml 2>/dev/null
} | grep -E '^[[:space:]]*(- )?image: |prometheus-config-reloader=' \
  | sed -E 's/.*(image: *|prometheus-config-reloader=)"?//; s/"?[[:space:]]*$//' | grep -E '[:@]' | sort -u
