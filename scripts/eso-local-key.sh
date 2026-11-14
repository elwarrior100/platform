#!/usr/bin/env bash
# Creates the one Secret the local cluster needs before the External Secrets Operator can read the vault:
# the eso-reader private key ("secret zero"). Read from ~/.oci/eso-reader/ and never printed.
# The Oracle cluster does not need this (instance principal).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"
KEY="${ESO_READER_KEY:-$HOME/.oci/eso-reader/key.pem}"
[ -r "$KEY" ] || { echo "private key not found: $KEY" >&2; exit 1; }
FP="$(terraform -chdir="$ROOT/terraform/oracle" output -json eso_reader | python3 -c 'import json,sys; print(json.load(sys.stdin)["fingerprint"])')"
kubectl get ns external-secrets >/dev/null 2>&1 || kubectl create ns external-secrets
kubectl -n external-secrets create secret generic oci-eso-reader \
  --from-file=privateKey="$KEY" --from-literal=fingerprint="$FP" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "secret external-secrets/oci-eso-reader ready"
