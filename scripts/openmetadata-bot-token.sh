#!/usr/bin/env bash
# Stores the JWT of OpenMetadata's ingestion bot in the vault, for the Airflow tasks that publish the catalog and the
# G2 history (ADR-009, decision 5): vault secret airflow-openmetadata-bot-<env> {"token": ...}, read by
# envs/<env>/secret-store/openmetadata-bot.yaml into the airflow namespace. Idempotent: an existing secret is kept.
# Logs in with the admin password from the vault (openmetadata-admin-<env>). Nothing is printed, nothing in arguments.
# Usage: KUBECONFIG=<the env's kubeconfig> ./scripts/openmetadata-bot-token.sh <local|oracle>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"; show_target
ENV="${1:?environment: local or oracle}"
NAME="airflow-openmetadata-bot-$ENV"
tf() { terraform -chdir="$ROOT/terraform/oracle" output -raw "$1"; }
VAULT="$(tf vault_ocid)"; KEY="$(tf master_key_ocid)"; COMPARTMENT="$(tf secrets_compartment_ocid)"
if [ -n "$(oci vault secret list --compartment-id "$COMPARTMENT" --vault-id "$VAULT" --name "$NAME" --lifecycle-state ACTIVE --query 'data[0].id' --raw-output 2>/dev/null)" ]; then
  echo "vault: $NAME already exists"; exit 0
fi
TMP="$(mktemp -d)"; chmod 700 "$TMP"
kubectl -n openmetadata port-forward svc/openmetadata 18014:8585 >/dev/null 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null; wait $PF 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 20); do nc -z 127.0.0.1 18014 2>/dev/null && break; sleep 1; done
( umask 077; "$(dirname "$0")/vault-get.sh" "openmetadata-admin-$ENV" password > "$TMP/admin" )
python3 - "$COMPARTMENT" "$VAULT" "$KEY" "$NAME" "$TMP/admin" "$TMP/new.json" <<'PY'
import base64, json, os, sys, urllib.request
comp, vault, key, name, admin_file, out = sys.argv[1:]
base = "http://127.0.0.1:18014/api/v1"
def call(method, path, body=None, token=None):
    req = urllib.request.Request(base + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", **({"Authorization": "Bearer " + token} if token else {})})
    return json.load(urllib.request.urlopen(req, timeout=20))
pw = open(admin_file).read().strip()
admin = call("POST", "/users/login", {"email": "admin@open-metadata.org", "password": base64.b64encode(pw.encode()).decode()})["accessToken"]
bot = call("GET", "/bots/name/ingestion-bot?fields=botUser", token=admin)
jwt = call("GET", f"/users/auth-mechanism/{bot['botUser']['id']}", token=admin)["config"]["JWTToken"]
content = base64.b64encode(json.dumps({"token": jwt}).encode()).decode()
fd = os.open(out, os.O_WRONLY | os.O_CREAT, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump({"compartmentId": comp, "vaultId": vault, "keyId": key, "secretName": name, "secretContentContent": content,
               "description": "OpenMetadata ingestion-bot JWT for Airflow tasks (scripts/openmetadata-bot-token.sh)"}, f)
PY
oci vault secret create-base64 --from-json "file://$TMP/new.json" >/dev/null
echo "vault: created $NAME"
