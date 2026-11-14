#!/usr/bin/env bash
# Waits until the External Secrets Operator has created the platform Secrets from the OCI Vault (ADR-011).
# Replaces the old bootstrap-secrets.sh, which generated passwords inside each cluster: now every cluster reads
# the same values from the vault, and nothing is generated here.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"
show_target

for s in data/postgres-auth data/seaweedfs-auth data/seaweedfs-s3-config data/lakefs-auth \
         ingest/ingest-db ingest/lakefs-credentials; do
  wait_secret "${s%%/*}" "${s#*/}" && echo "ok: $s"
done
