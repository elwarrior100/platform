#!/usr/bin/env bash
# Replaces Argo CD's initial admin password with one kept in the vault (idempotent). One password per environment:
# vault secret platform-argocd-admin-<env>. The cluster only keeps its bcrypt hash (argocd-secret, which the argocd
# application ignores), and the argocd-initial-admin-secret is deleted. Nothing is printed.
# Read it later:  ./scripts/vault-get.sh platform-argocd-admin-<env> password | pbcopy
# Usage: KUBECONFIG=... ./scripts/argocd-admin-password.sh <local|oracle>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"
ENV="${1:?environment: local or oracle}"
NAME="platform-argocd-admin-$ENV"
tf() { terraform -chdir="$ROOT/terraform/oracle" output -raw "$1"; }
VAULT="$(tf vault_ocid)"; KEY="$(tf master_key_ocid)"; COMPARTMENT="$(tf secrets_compartment_ocid)"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT

# 1. the password in the vault (generated once)
if [ -z "$(oci vault secret list --compartment-id "$COMPARTMENT" --vault-id "$VAULT" --name "$NAME" --lifecycle-state ACTIVE --query 'data[0].id' --raw-output 2>/dev/null)" ]; then
  python3 - "$COMPARTMENT" "$VAULT" "$KEY" "$NAME" "$TMP/new.json" <<'PY'
import base64, json, secrets, string, sys
comp, vault, key, name, out = sys.argv[1:]
pw = "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(28))
content = base64.b64encode(json.dumps({"username": "admin", "password": pw}).encode()).decode()
json.dump({"compartmentId": comp, "vaultId": vault, "keyId": key, "secretName": name, "secretContentContent": content,
           "description": "Argo CD admin password (scripts/argocd-admin-password.sh)"}, open(out, "w"))
PY
  chmod 600 "$TMP/new.json"
  oci vault secret create-base64 --from-json "file://$TMP/new.json" >/dev/null; rm -f "$TMP/new.json"
  echo "vault: created $NAME"
  for _ in $(seq 1 30); do oci secrets secret-bundle get-secret-bundle-by-name --vault-id "$VAULT" --secret-name "$NAME" >/dev/null 2>&1 && break; sleep 3; done
fi

# 2. its bcrypt hash into argocd-secret (the password itself never leaves this pipe)
oci secrets secret-bundle get-secret-bundle-by-name --vault-id "$VAULT" --secret-name "$NAME" \
  --query 'data."secret-bundle-content".content' --raw-output \
  | uv run -q --with bcrypt python -c '
import base64, bcrypt, json, sys, datetime
pw = json.loads(base64.b64decode(sys.stdin.read()))["password"].encode()
h = bcrypt.hashpw(pw, bcrypt.gensalt(10)).decode()
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
print(json.dumps({"stringData": {"admin.password": h, "admin.passwordMtime": now}}))' > "$TMP/patch.json"
chmod 600 "$TMP/patch.json"
kubectl -n argocd patch secret argocd-secret --type merge --patch-file "$TMP/patch.json" >/dev/null
echo "argocd-secret: admin password set from $NAME"

# 3. the initial password is no longer valid: remove the Secret that held it
kubectl -n argocd delete secret argocd-initial-admin-secret --ignore-not-found >/dev/null
echo "argocd-initial-admin-secret deleted"
