#!/usr/bin/env bash
# Stores the Tailscale operator's OAuth client in the OCI Vault as tailscale-operator-oauth
# ({"client_id": ..., "client_secret": ...}); the External Secrets Operator delivers it to the tailscale namespace.
# Run it YOURSELF in a terminal: it asks for both values without echoing them. They never appear as a command
# argument, in the shell history or on screen; the request body lives in a private temp file, deleted on exit.
# Run again to store a new version (e.g. after rotating the client in the Tailscale console).
# Usage: ./scripts/tailscale-oauth-seed.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME=tailscale-operator-oauth
[ -t 0 ] || { echo "run it in a terminal: it reads the values from your keyboard" >&2; exit 1; }
tf() { terraform -chdir="$ROOT/terraform/oracle" output -raw "$1"; }
VAULT="$(tf vault_ocid)"; KEY="$(tf master_key_ocid)"; COMPARTMENT="$(tf secrets_compartment_ocid)"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT

printf 'Tailscale OAuth Client ID: '; IFS= read -rs CLIENT_ID; echo
printf 'Tailscale OAuth Client secret: '; IFS= read -rs CLIENT_SECRET; echo
[ -n "$CLIENT_ID" ] && [ -n "$CLIENT_SECRET" ] || { echo "both values are needed; nothing stored" >&2; exit 1; }
case "$CLIENT_SECRET" in tskey-client-*) ;; *) echo "warning: the secret usually starts with tskey-client-" >&2 ;; esac

ID="$(oci vault secret list --compartment-id "$COMPARTMENT" --vault-id "$VAULT" --name "$NAME" \
  --lifecycle-state ACTIVE --query 'data[0].id' --raw-output 2>/dev/null || true)"
export CLIENT_ID CLIENT_SECRET
python3 - "$COMPARTMENT" "$VAULT" "$KEY" "$NAME" "${ID:-}" "$TMP/body.json" <<'PY'
import base64, json, os, sys
comp, vault, key, name, sid, out = sys.argv[1:]
content = base64.b64encode(json.dumps({"client_id": os.environ["CLIENT_ID"],
                                       "client_secret": os.environ["CLIENT_SECRET"]}).encode()).decode()
body = ({"secretId": sid, "secretContentContent": content} if sid and sid != "null" else
        {"compartmentId": comp, "vaultId": vault, "keyId": key, "secretName": name, "secretContentContent": content,
         "description": "Tailscale Kubernetes operator OAuth client (scripts/tailscale-oauth-seed.sh)"})
json.dump(body, open(out, "w"))
PY
unset CLIENT_ID CLIENT_SECRET
chmod 600 "$TMP/body.json"
if [ -n "$ID" ] && [ "$ID" != "null" ]; then
  oci vault secret update-base64 --from-json "file://$TMP/body.json" >/dev/null; echo "vault: new version of $NAME"
else
  oci vault secret create-base64 --from-json "file://$TMP/body.json" >/dev/null; echo "vault: created $NAME"
fi
