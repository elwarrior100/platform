#!/usr/bin/env bash
# Cria os Secrets da plataforma se ainda não existirem. Idempotente.
# As palavras-passe são aleatórias e nunca são impressas nem guardadas no git.
set -euo pipefail

NS=data
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

rand() { openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-24; }

if ! kubectl -n "$NS" get secret postgres-auth >/dev/null 2>&1; then
  kubectl -n "$NS" create secret generic postgres-auth \
    --from-literal=POSTGRES_PASSWORD="$(rand)" \
    --from-literal=LAKEFS_DB_PASSWORD="$(rand)"
  echo "secret postgres-auth criado"
else
  echo "secret postgres-auth já existe"
fi

# SeaweedFS (S3): chaves de acesso e o JSON de identidades lido pelo gateway S3.
if ! kubectl -n "$NS" get secret seaweedfs-auth >/dev/null 2>&1; then
  AK="$(rand)"; SK="$(rand)"
  kubectl -n "$NS" create secret generic seaweedfs-auth \
    --from-literal=S3_ACCESS_KEY="$AK" \
    --from-literal=S3_SECRET_KEY="$SK"
  printf '{"identities":[{"name":"platform","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":["Admin","Read","Write","List","Tagging"]}]}' "$AK" "$SK" |
    kubectl -n "$NS" create secret generic seaweedfs-s3-config --from-file=s3.json=/dev/stdin
  echo "secrets seaweedfs-auth e seaweedfs-s3-config criados"
else
  echo "secret seaweedfs-auth já existe"
fi
