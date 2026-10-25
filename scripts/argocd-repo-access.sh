#!/usr/bin/env bash
# Dá ao Argo CD acesso de LEITURA ao repositório privado, com uma deploy key.
# Uso: argocd-repo-access.sh <caminho-da-chave-privada>
# A chave lê-se de um ficheiro; nunca é impressa nem passa por argumentos de comando.
set -euo pipefail
KEY="${1:?caminho da chave privada (ex.: ~/.ssh/argocd_deploy)}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"
REPO="git@github.com:elwarrior100/modbus_data_plataform.git"

[ -r "$KEY" ] || { echo "chave não encontrada: $KEY" >&2; exit 1; }
kubectl -n argocd delete secret repo-modbus --ignore-not-found >/dev/null
kubectl -n argocd create secret generic repo-modbus \
  --from-literal=type=git --from-literal=url="$REPO" --from-file=sshPrivateKey="$KEY"
kubectl -n argocd label secret repo-modbus argocd.argoproj.io/secret-type=repository
echo "acesso configurado para $REPO"
