#!/usr/bin/env bash
# Makes sure the BI database "serving" and its owner role "serving" exist (modbus ADR-022, S1), with the password from
# the vault. The gold_daily task "serve" fills it (one copy of each gold release, views that follow LATEST_STABLE).
# The Secret airflow/serving-db comes from the External Secrets Operator. Idempotent; nothing is printed.
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"
show_target

wait_secret airflow serving-db
secret_value airflow serving-db SERVING_DATABASE_URL | url_password | ensure_pg_role serving serving
echo "database and user serving ready"
