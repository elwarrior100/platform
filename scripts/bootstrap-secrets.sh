#!/usr/bin/env bash
# Creates the platform Secrets if they do not exist yet. Idempotent.
# Passwords are random and never printed nor stored in git.
set -euo pipefail

NS=data
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

rand() { openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-24; }

if ! kubectl -n "$NS" get secret postgres-auth >/dev/null 2>&1; then
  kubectl -n "$NS" create secret generic postgres-auth \
    --from-literal=POSTGRES_PASSWORD="$(rand)" \
    --from-literal=LAKEFS_DB_PASSWORD="$(rand)"
  echo "secret postgres-auth created"
else
  echo "secret postgres-auth already exists"
fi

# SeaweedFS (S3): access keys and the identities JSON read by the S3 gateway.
if ! kubectl -n "$NS" get secret seaweedfs-auth >/dev/null 2>&1; then
  AK="$(rand)"; SK="$(rand)"
  kubectl -n "$NS" create secret generic seaweedfs-auth \
    --from-literal=S3_ACCESS_KEY="$AK" \
    --from-literal=S3_SECRET_KEY="$SK"
  printf '{"identities":[{"name":"platform","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":["Admin","Read","Write","List","Tagging"]}]}' "$AK" "$SK" |
    kubectl -n "$NS" create secret generic seaweedfs-s3-config --from-file=s3.json=/dev/stdin
  echo "secrets seaweedfs-auth and seaweedfs-s3-config created"
else
  echo "secret seaweedfs-auth already exists"
fi

# lakeFS: internal encryption key and the initial admin credentials.
if ! kubectl -n "$NS" get secret lakefs-auth >/dev/null 2>&1; then
  kubectl -n "$NS" create secret generic lakefs-auth \
    --from-literal=AUTH_ENCRYPT_SECRET_KEY="$(openssl rand -hex 32)" \
    --from-literal=ADMIN_ACCESS_KEY_ID="AKIA$(openssl rand -hex 8 | tr 'a-f' 'A-F')" \
    --from-literal=ADMIN_SECRET_ACCESS_KEY="$(openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-40)"
  echo "secret lakefs-auth created"
else
  echo "secret lakefs-auth already exists"
fi

# ingest: copies the lakeFS credentials into the writer namespace (a Secret does not cross namespaces).
# lakeFS open source has no per-user permissions, so this is the admin account.
kubectl get ns ingest >/dev/null 2>&1 || kubectl create ns ingest
if ! kubectl -n ingest get secret lakefs-credentials >/dev/null 2>&1; then
  kubectl -n ingest create secret generic lakefs-credentials \
    --from-literal=LAKEFS_ACCESS_KEY_ID="$(kubectl -n "$NS" get secret lakefs-auth -o jsonpath='{.data.ADMIN_ACCESS_KEY_ID}' | base64 -d)" \
    --from-literal=LAKEFS_SECRET_ACCESS_KEY="$(kubectl -n "$NS" get secret lakefs-auth -o jsonpath='{.data.ADMIN_SECRET_ACCESS_KEY}' | base64 -d)"
  echo "secret lakefs-credentials created in ingest"
else
  echo "secret lakefs-credentials already exists"
fi
