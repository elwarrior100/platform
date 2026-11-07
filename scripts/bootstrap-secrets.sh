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

# lakeFS: chave de cifra interna e credenciais do administrador inicial.
if ! kubectl -n "$NS" get secret lakefs-auth >/dev/null 2>&1; then
  kubectl -n "$NS" create secret generic lakefs-auth \
    --from-literal=AUTH_ENCRYPT_SECRET_KEY="$(openssl rand -hex 32)" \
    --from-literal=ADMIN_ACCESS_KEY_ID="AKIA$(openssl rand -hex 8 | tr 'a-f' 'A-F')" \
    --from-literal=ADMIN_SECRET_ACCESS_KEY="$(openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-40)"
  echo "secret lakefs-auth criado"
else
  echo "secret lakefs-auth já existe"
fi

# ingest: copia as credenciais do lakeFS para o namespace do writer (um Secret não atravessa namespaces).
# lakeFS open source não tem permissões por utilizador, por isso é a conta de administrador.
kubectl get ns ingest >/dev/null 2>&1 || kubectl create ns ingest
if ! kubectl -n ingest get secret lakefs-credentials >/dev/null 2>&1; then
  kubectl -n ingest create secret generic lakefs-credentials \
    --from-literal=LAKEFS_ACCESS_KEY_ID="$(kubectl -n "$NS" get secret lakefs-auth -o jsonpath='{.data.ADMIN_ACCESS_KEY_ID}' | base64 -d)" \
    --from-literal=LAKEFS_SECRET_ACCESS_KEY="$(kubectl -n "$NS" get secret lakefs-auth -o jsonpath='{.data.ADMIN_SECRET_ACCESS_KEY}' | base64 -d)"
  echo "secret lakefs-credentials criado em ingest"
else
  echo "secret lakefs-credentials já existe"
fi
