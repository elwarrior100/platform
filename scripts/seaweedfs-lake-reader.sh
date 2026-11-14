#!/usr/bin/env bash
# Gives the nightly lake copy (backup/lake-sync) its own SeaweedFS S3 identity that can only READ and LIST the bucket
# "lake", instead of the platform admin key. Idempotent, nothing is printed, no value is passed as an argument.
#   1. vault secret backup-seaweedfs-reader {S3_ACCESS_KEY, S3_SECRET_KEY}  (generated once)
#   2. identity "lake-reader" (actions Read:lake, List:lake) added to the vault secret data-seaweedfs-s3-config (s3.json),
#      shared by both clusters; a new version is written only when the identity is missing or its key changed
# Afterwards, per cluster: refresh the ExternalSecrets and restart SeaweedFS (it reads s3.json at start-up):
#   KUBECONFIG=... ./scripts/seaweedfs-lake-reader.sh --apply
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tf() { terraform -chdir="$ROOT/terraform/oracle" output -raw "$1"; }
VAULT="$(tf vault_ocid)"; KEY="$(tf master_key_ocid)"; COMPARTMENT="$(tf secrets_compartment_ocid)"
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
READER=backup-seaweedfs-reader; S3CFG=data-seaweedfs-s3-config

secret_id() { oci vault secret list --compartment-id "$COMPARTMENT" --vault-id "$VAULT" --name "$1" \
  --lifecycle-state ACTIVE --query 'data[0].id' --raw-output 2>/dev/null || true; }
bundle() { oci secrets secret-bundle get-secret-bundle-by-name --vault-id "$VAULT" --secret-name "$1" \
  --query 'data."secret-bundle-content".content' --raw-output; }

if [ "${1:-}" != "--apply" ]; then
  # 1. the reader key, generated once
  if [ -z "$(secret_id "$READER")" ]; then
    python3 - "$COMPARTMENT" "$VAULT" "$KEY" "$READER" "$TMP/new.json" <<'PY'
import base64, json, secrets, string, sys
comp, vault, key, name, out = sys.argv[1:]
alnum = string.ascii_letters + string.digits
cred = {"S3_ACCESS_KEY": "".join(secrets.choice(string.ascii_uppercase + string.digits) for _ in range(20)),
        "S3_SECRET_KEY": "".join(secrets.choice(alnum) for _ in range(40))}
json.dump({"compartmentId": comp, "vaultId": vault, "keyId": key, "secretName": name,
           "secretContentContent": base64.b64encode(json.dumps(cred).encode()).decode(),
           "description": "SeaweedFS read-only key for the lake copy (scripts/seaweedfs-lake-reader.sh)"}, open(out, "w"))
PY
    chmod 600 "$TMP/new.json"; oci vault secret create-base64 --from-json "file://$TMP/new.json" >/dev/null
    echo "vault: created $READER"
    for _ in $(seq 1 30); do bundle "$READER" >/dev/null 2>&1 && break; sleep 3; done
  fi

  # 2. the identity in s3.json
  bundle "$READER" > "$TMP/reader.b64"; bundle "$S3CFG" > "$TMP/s3cfg.b64"; chmod 600 "$TMP"/*.b64
  python3 - "$TMP/reader.b64" "$TMP/s3cfg.b64" "$(secret_id "$S3CFG")" "$TMP/update.json" <<'PY'
import base64, json, sys
reader_f, cfg_f, sid, out = sys.argv[1:]
r = json.loads(base64.b64decode(open(reader_f).read()))
outer = json.loads(base64.b64decode(open(cfg_f).read()))      # {"s3.json": "<json text>"}
cfg = json.loads(outer["s3.json"])
want = {"name": "lake-reader", "actions": ["Read:lake", "List:lake"],
        "credentials": [{"accessKey": r["S3_ACCESS_KEY"], "secretKey": r["S3_SECRET_KEY"]}]}
ids = [i for i in cfg["identities"] if i.get("name") != "lake-reader"]
if [i for i in cfg["identities"] if i.get("name") == "lake-reader"] == [want]:
    print("s3.json: lake-reader already present"); sys.exit(0)
cfg["identities"] = ids + [want]
outer["s3.json"] = json.dumps(cfg, indent=2)
json.dump({"secretId": sid, "secretContentContent": base64.b64encode(json.dumps(outer, separators=(",", ":")).encode()).decode()},
          open(out, "w"))
print("s3.json: lake-reader added")
PY
  if [ -f "$TMP/update.json" ]; then
    chmod 600 "$TMP/update.json"; oci vault secret update-base64 --from-json "file://$TMP/update.json" >/dev/null
    echo "vault: new version of $S3CFG"
  fi
  echo "next, per cluster: KUBECONFIG=... $0 --apply"
  exit 0
fi

# --apply: on the cluster in KUBECONFIG
: "${KUBECONFIG:?set KUBECONFIG}"
now=$(date +%s)
kubectl -n data annotate externalsecret seaweedfs-s3-config force-sync="$now" --overwrite >/dev/null
kubectl -n backup annotate externalsecret seaweedfs-s3 force-sync="$now" --overwrite >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
  kubectl -n data get secret seaweedfs-s3-config -o jsonpath='{.data.s3\.json}' | base64 -d | grep -q '"lake-reader"' && break; sleep 2
done
kubectl -n data get secret seaweedfs-s3-config -o jsonpath='{.data.s3\.json}' | base64 -d | grep -q '"lake-reader"' \
  || { echo "seaweedfs-s3-config has no lake-reader yet" >&2; exit 1; }
# delete the pod rather than `rollout restart`: that would add an annotation Argo CD sees as drift and reverts
kubectl -n data delete pod seaweedfs-0 --wait=true >/dev/null
kubectl -n data wait pod seaweedfs-0 --for=condition=Ready --timeout=180s >/dev/null
echo "SeaweedFS restarted with the lake-reader identity"
