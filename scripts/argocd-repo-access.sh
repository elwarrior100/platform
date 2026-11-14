#!/usr/bin/env bash
# Gives Argo CD READ access to a private repository with a deploy key (not needed for this public repo).
# Usage: argocd-repo-access.sh <private-key-path>
# The key is read from a file; it is never printed nor passed as a command argument.
set -euo pipefail
KEY="${1:?private key path (e.g. ~/.ssh/argocd_deploy)}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"
REPO="git@github.com:elwarrior100/modbus_data_plataform.git"

[ -r "$KEY" ] || { echo "key not found: $KEY" >&2; exit 1; }
kubectl -n argocd delete secret repo-modbus --ignore-not-found >/dev/null
kubectl -n argocd create secret generic repo-modbus \
  --from-literal=type=git --from-literal=url="$REPO" --from-file=sshPrivateKey="$KEY"
kubectl -n argocd label secret repo-modbus argocd.argoproj.io/secret-type=repository
echo "access configured for $REPO"
