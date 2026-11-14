#!/usr/bin/env bash
# Installs (or upgrades) Argo CD in the cluster. Idempotent.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"
CHART_VERSION=10.11.1

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd --version "$CHART_VERSION" \
  --namespace argocd --create-namespace \
  -f "$ROOT/platform/argocd/values.yaml" --wait --timeout 8m

# The root application lives in the AppProject "bootstrap", which root itself also syncs afterwards. On an empty
# cluster it does not exist yet, so Argo CD would refuse root: create it here, before root-app.yaml is applied.
kubectl apply -f "$ROOT/platform/argocd/projects/bootstrap.yaml"
