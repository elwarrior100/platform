#!/usr/bin/env bash
# Prints ONE field of a vault secret to stdout, for piping (e.g. into pbcopy). Never run it without a pipe.
# Usage: ./scripts/vault-get.sh <vault-secret-name> <field> | pbcopy
#   ./scripts/vault-get.sh platform-argocd-admin-oracle password | pbcopy
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${1:?vault secret name}"; FIELD="${2:?field}"
[ -t 1 ] && { echo "refused: pipe the output (e.g. | pbcopy), it is a secret" >&2; exit 1; }
VAULT="$(terraform -chdir="$ROOT/terraform/oracle" output -raw vault_ocid)"
oci secrets secret-bundle get-secret-bundle-by-name --vault-id "$VAULT" --secret-name "$NAME" \
  --query 'data."secret-bundle-content".content' --raw-output \
  | python3 -c 'import base64, json, sys; sys.stdout.write(json.loads(base64.b64decode(sys.stdin.read()))[sys.argv[1]])' "$FIELD"
