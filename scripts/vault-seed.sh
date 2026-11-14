#!/usr/bin/env bash
# Copies the platform Secrets from a running cluster into the OCI Vault (ADR-011). Idempotent.
#
# One vault secret per Kubernetes Secret, holding all its keys as JSON ({"KEY": "value", ...}), so the
# External Secrets Operator can rebuild the Secret with a single `dataFrom.extract`.
# Vault secret name: <namespace>-<secret>, e.g. data-postgres-auth.
#
# Values are COPIED, not regenerated: new passwords would break the databases that already use them.
# A secret that already exists in the vault is left alone (use --update to add a new version from the cluster).
# Nothing is printed and no value is passed as a command argument: the request body goes through a temporary
# file readable only by you, deleted on exit.
#
# Usage: ./scripts/vault-seed.sh [--update]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"
MODE="${1:-}"

# The source of truth for each secret. Copies (lakefs-credentials in ingest and airflow) are not stored:
# the External Secrets Operator derives them from data-lakefs-auth.
SECRETS=(
  data/postgres-auth
  data/seaweedfs-auth
  data/seaweedfs-s3-config
  data/lakefs-auth
  ingest/ingest-db
  airflow/airflow-metadata
  airflow/airflow-fernet
  airflow/airflow-api-secret
  airflow/airflow-jwt
  airflow/airflow-admin
  openmetadata/openmetadata-db
)

tf() { terraform -chdir="$ROOT/terraform/oracle" output -raw "$1"; }
VAULT="$(tf vault_ocid)"
KEY="$(tf master_key_ocid)"
COMPARTMENT="$(tf secrets_compartment_ocid)"

kubectl get nodes >/dev/null 2>&1 || { echo "Cannot reach the cluster. Start it with ./scripts/vm-start.sh" >&2; exit 1; }

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

exists() {   # prints the secret OCID if an ACTIVE secret with this name exists in the vault
  oci vault secret list --compartment-id "$COMPARTMENT" --vault-id "$VAULT" --name "$1" \
    --lifecycle-state ACTIVE --query 'data[0].id' --raw-output 2>/dev/null || true
}

created=0; updated=0; skipped=0
for item in "${SECRETS[@]}"; do
  ns="${item%%/*}"; name="${item#*/}"; vname="$ns-$name"
  if ! kubectl -n "$ns" get secret "$name" >/dev/null 2>&1; then
    echo "MISSING in cluster: $ns/$name (skipped)" >&2; skipped=$((skipped + 1)); continue
  fi
  id="$(exists "$vname")"
  if [ -n "$id" ] && [ "$id" != "null" ] && [ "$MODE" != "--update" ]; then
    echo "already in vault: $vname"; skipped=$((skipped + 1)); continue
  fi

  # Build the request body in the private temp dir: the Secret's data map (already base64 per key) is decoded
  # into plain JSON, then base64-encoded as the vault secret content. Python reads it from stdin, not argv.
  kubectl -n "$ns" get secret "$name" -o json | python3 -c '
import base64, json, sys
mode, vault, key, comp, vname, secret_id = sys.argv[1:7]
data = json.load(sys.stdin)["data"]
plain = {k: base64.b64decode(v).decode() for k, v in sorted(data.items())}
content = base64.b64encode(json.dumps(plain, separators=(",", ":")).encode()).decode()
if mode == "create":
    body = {"compartmentId": comp, "vaultId": vault, "keyId": key, "secretName": vname,
            "secretContentContent": content, "description": "copied from the cluster by vault-seed.sh"}
else:
    body = {"secretId": secret_id, "secretContentContent": content}
json.dump(body, open(sys.argv[7], "w"))
' "$([ -n "$id" ] && [ "$id" != "null" ] && echo update || echo create)" "$VAULT" "$KEY" "$COMPARTMENT" "$vname" "${id:-}" "$TMP/body.json"
  chmod 600 "$TMP/body.json"

  if [ -n "$id" ] && [ "$id" != "null" ]; then
    oci vault secret update-base64 --from-json "file://$TMP/body.json" >/dev/null
    echo "new version in vault: $vname"; updated=$((updated + 1))
  else
    oci vault secret create-base64 --from-json "file://$TMP/body.json" >/dev/null
    echo "created in vault: $vname"; created=$((created + 1))
  fi
  rm -f "$TMP/body.json"
done
echo "done: $created created, $updated updated, $skipped skipped"
