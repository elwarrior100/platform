#!/usr/bin/env bash
# Makes sure the "ingest" database and user exist in PostgreSQL, with the password from the vault.
# The Secret ingest/ingest-db itself comes from the External Secrets Operator. Idempotent; nothing is printed.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"

wait_secret ingest ingest-db
secret_value ingest ingest-db DATABASE_URL | url_password | ensure_pg_role ingest ingest
echo "database and user ingest ready"
