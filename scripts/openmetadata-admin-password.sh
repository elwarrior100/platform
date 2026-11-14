#!/usr/bin/env bash
# Replaces OpenMetadata's default admin password (admin@open-metadata.org / admin, public in its docs) with one kept
# in the vault (idempotent). One password per environment: vault secret openmetadata-admin-<env>. Nothing is printed.
# Read it later:  ./scripts/vault-get.sh openmetadata-admin-<env> password | pbcopy
# Usage: KUBECONFIG=... ./scripts/openmetadata-admin-password.sh <local|oracle>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"
ENV="${1:?environment: local or oracle}"
NAME="openmetadata-admin-$ENV"
tf() { terraform -chdir="$ROOT/terraform/oracle" output -raw "$1"; }
VAULT="$(tf vault_ocid)"; KEY="$(tf master_key_ocid)"; COMPARTMENT="$(tf secrets_compartment_ocid)"
TMP="$(mktemp -d)"; chmod 700 "$TMP"
kubectl -n openmetadata port-forward svc/openmetadata 18013:8585 >/dev/null 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null; wait $PF 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 20); do nc -z 127.0.0.1 18013 2>/dev/null && break; sleep 1; done

# 1. the new password in the vault (generated once; meets OpenMetadata's policy: upper, lower, digit, symbol)
if [ -z "$(oci vault secret list --compartment-id "$COMPARTMENT" --vault-id "$VAULT" --name "$NAME" --lifecycle-state ACTIVE --query 'data[0].id' --raw-output 2>/dev/null)" ]; then
  python3 - "$COMPARTMENT" "$VAULT" "$KEY" "$NAME" "$TMP/new.json" <<'PY'
import base64, json, secrets, string, sys
comp, vault, key, name, out = sys.argv[1:]
pw = "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(20)) + "Aa1#"
content = base64.b64encode(json.dumps({"username": "admin@open-metadata.org", "password": pw}).encode()).decode()
json.dump({"compartmentId": comp, "vaultId": vault, "keyId": key, "secretName": name, "secretContentContent": content,
           "description": "OpenMetadata admin password (scripts/openmetadata-admin-password.sh)"}, open(out, "w"))
PY
  chmod 600 "$TMP/new.json"
  oci vault secret create-base64 --from-json "file://$TMP/new.json" >/dev/null; rm -f "$TMP/new.json"
  echo "vault: created $NAME"
  for _ in $(seq 1 30); do oci secrets secret-bundle get-secret-bundle-by-name --vault-id "$VAULT" --secret-name "$NAME" >/dev/null 2>&1 && break; sleep 3; done
fi

# 2. log in (with the vault password if already applied, else the default) and change it
oci secrets secret-bundle get-secret-bundle-by-name --vault-id "$VAULT" --secret-name "$NAME" \
  --query 'data."secret-bundle-content".content' --raw-output | python3 -c '
import base64, json, sys, urllib.request, urllib.error
API = "http://127.0.0.1:18013/api/v1"
new = json.loads(base64.b64decode(sys.stdin.read()))["password"]
def call(method, path, body, token=None):
    h = {"Content-Type": "application/json"}
    if token: h["Authorization"] = "Bearer " + token
    req = urllib.request.Request(API + path, data=json.dumps(body).encode(), headers=h, method=method)
    try:
        r = urllib.request.urlopen(req); raw = r.read(); return r.status, (json.loads(raw) if raw.strip() else {})
    except urllib.error.HTTPError as e: return e.code, {}
def login(pw):
    code, body = call("POST", "/users/login", {"email": "admin@open-metadata.org", "password": base64.b64encode(pw.encode()).decode()})
    return body.get("accessToken") if code == 200 else None
if login(new):
    print("OpenMetadata: admin already uses the vault password"); sys.exit(0)
token = login("admin")
if not token:
    print("OpenMetadata: neither the vault nor the default password works; nothing changed"); sys.exit(1)
code, _ = call("PUT", "/users/changePassword", {"username": "admin", "oldPassword": "admin", "newPassword": new,
                                               "confirmPassword": new, "requestType": "SELF"}, token)
ok = code in (200, 204) and login(new) and not login("admin")
print("OpenMetadata: admin password changed (default refused, vault password accepted)" if ok else f"OpenMetadata: change failed (HTTP {code})")
sys.exit(0 if ok else 1)'
