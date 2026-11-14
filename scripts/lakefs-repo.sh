#!/usr/bin/env bash
# Creates a project's lakeFS repository (and its SeaweedFS bucket) on a fresh cluster. Idempotent.
# Usage: ./scripts/lakefs-repo.sh <repository> <bucket>      e.g. industrial-lake lake
#
# Each project gets its own lakeFS repository (ADR-010). The project then installs its own hooks
# (for modbus: quality/install_hooks.py). The admin credentials are read from the lakefs-auth Secret and passed to
# curl through a private config file, never as arguments.
set -euo pipefail
REPO="${1:?repository name}"
BUCKET="${2:?bucket name}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"
. "$(dirname "$0")/lib.sh"

wait_secret data lakefs-auth
kubectl -n data rollout status statefulset/seaweedfs --timeout=300s >/dev/null
kubectl -n data rollout status deployment/lakefs --timeout=300s >/dev/null

# 1. the bucket in SeaweedFS (its S3 gateway does not create buckets on first write)
if kubectl -n data exec seaweedfs-0 -- sh -c 'echo s3.bucket.list | weed shell 2>/dev/null' | grep -qE "^\s*$BUCKET\s"; then
  echo "bucket $BUCKET already exists"
else
  kubectl -n data exec seaweedfs-0 -- sh -c "echo 's3.bucket.create -name $BUCKET' | weed shell" >/dev/null
  echo "bucket $BUCKET created"
fi

# 2. the lakeFS repository, through a temporary port-forward
TMP="$(mktemp -d)"; chmod 700 "$TMP"
kubectl -n data port-forward svc/lakefs 18000:8000 >/dev/null 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null; wait $PF 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 20); do nc -z 127.0.0.1 18000 2>/dev/null && break; sleep 1; done
printf 'user = "%s:%s"\n' "$(secret_value data lakefs-auth ADMIN_ACCESS_KEY_ID)" "$(secret_value data lakefs-auth ADMIN_SECRET_ACCESS_KEY)" > "$TMP/curl.cfg"
chmod 600 "$TMP/curl.cfg"
API=http://127.0.0.1:18000/api/v1

# A fresh lakeFS is "not_initialized" (the LAKEFS_INSTALLATION_* variables alone did not set it up): create the
# admin user with the access key from the vault, so every cluster uses the same credentials.
if curl -s "$API/setup_lakefs" | grep -q '"state":"not_initialized"'; then
  ( AK="$(secret_value data lakefs-auth ADMIN_ACCESS_KEY_ID)"; SK="$(secret_value data lakefs-auth ADMIN_SECRET_ACCESS_KEY)"
    printf '{"username":"admin","key":{"access_key_id":"%s","secret_access_key":"%s"}}' "$AK" "$SK" > "$TMP/setup.json" )
  chmod 600 "$TMP/setup.json"
  curl -sS --fail-with-body -H 'Content-Type: application/json' -X POST "$API/setup_lakefs" -d @"$TMP/setup.json" >/dev/null
  curl -sS -H 'Content-Type: application/json' -X POST "$API/setup_comm_prefs" \
    -d '{"email":"","featureUpdates":false,"securityUpdates":false}' >/dev/null || true
  rm -f "$TMP/setup.json"
  echo "lakeFS initialised (admin user with the vault access key)"
fi

code=$(curl -s -o /dev/null -w '%{http_code}' -K "$TMP/curl.cfg" "$API/repositories/$REPO")
if [ "$code" = 200 ]; then
  echo "repository $REPO already exists"
else
  curl -sS --fail-with-body -K "$TMP/curl.cfg" -H 'Content-Type: application/json' -X POST "$API/repositories" \
    -d "{\"name\":\"$REPO\",\"storage_namespace\":\"s3://$BUCKET\",\"default_branch\":\"main\"}" >/dev/null
  echo "repository $REPO created (s3://$BUCKET, branch main)"
fi
