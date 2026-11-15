#!/usr/bin/env bash
# Monthly prune of the immutable lake copy (Object Storage bucket platform-lake-backup), run BY A PERSON from the Mac
# with their own OCI identity: the VM may create and read there but never delete (ADR-013), and that stays so.
# A copied object is a candidate only if it is no longer in the lake (lakeFS GC removed it) AND it was copied more
# than DAYS days ago, so a restore of any dump of the last weeks still finds its objects (ADR-015).
#   1. lake listing: a throw-away pod in the backup namespace with the READ-ONLY SeaweedFS key (labelled app=lake-sync,
#      the only label SeaweedFS accepts from backup)
#   2. copy listing: oci os object list, with your identity
#   3. report; with --apply, asks you to type the number of objects, then deletes exactly those
# Brakes: refuses an empty lake listing, and refuses to delete more than half of the copy (something is off).
# Usage: KUBECONFIG=~/.kube/oracle.yaml ./scripts/lake-backup-prune.sh [--apply] [days, default 30]
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:?set KUBECONFIG to the Oracle cluster}"
APPLY=false; [ "${1:-}" = "--apply" ] && { APPLY=true; shift; }
DAYS="${1:-30}"
BUCKET=platform-lake-backup
TMP="$(mktemp -d)"; chmod 700 "$TMP"
POD="lake-ls-$(date +%s)"
trap 'kubectl -n backup delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

echo "1/3 listing the lake (SeaweedFS, read-only key)..."
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $POD, namespace: backup, labels: {app: lake-sync}}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: ls
      image: rclone/rclone:1.71.2@sha256:3103526c506266a9ecdf064efe99bf3677d92ef6407af124d8c56b4f49cbaa51
      envFrom: [{secretRef: {name: seaweedfs-s3}}]
      env:
        - {name: RCLONE_CONFIG_LAKE_TYPE, value: s3}
        - {name: RCLONE_CONFIG_LAKE_PROVIDER, value: SeaweedFS}
        - {name: RCLONE_CONFIG_LAKE_ENDPOINT, value: "http://seaweedfs.data.svc.cluster.local:8333"}
        - {name: HOME, value: /tmp}
      command: [sh, -c, 'sleep 10; rclone lsf -R --files-only lake:lake && echo "#END"']
      securityContext: {runAsUser: 65534, allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
      resources: {requests: {cpu: 20m, memory: 64Mi}, limits: {memory: 256Mi}}
EOF
for _ in $(seq 1 60); do
  phase=$(kubectl -n backup get pod "$POD" -o jsonpath='{.status.phase}')
  case "$phase" in Succeeded|Failed) break ;; esac; sleep 3
done
kubectl -n backup logs "$POD" > "$TMP/lake.raw"
grep -qx '#END' "$TMP/lake.raw" || { echo "the lake listing did not finish (pod $phase); nothing done" >&2; exit 1; }
grep -vx '#END' "$TMP/lake.raw" | grep -v NOTICE | sort -u > "$TMP/lake.txt"
[ -s "$TMP/lake.txt" ] || { echo "the lake listing is empty: refusing (it would mark the whole copy)" >&2; exit 1; }

echo "2/3 listing the copy ($BUCKET, your identity)..."
NS=$(oci os ns get --query data --raw-output)
oci os object list -ns "$NS" -bn "$BUCKET" --all --fields name,timeCreated,size \
  --query 'data[].[name,"time-created",size]' --output json > "$TMP/copy.json"

echo "3/3 comparing (candidate: not in the lake and copied more than $DAYS days ago)..."
python3 - "$TMP/lake.txt" "$TMP/copy.json" "$DAYS" "$TMP/candidates.txt" <<'PY'
import datetime, json, sys
lake = set(open(sys.argv[1]).read().split("\n")) - {""}
copy = json.load(open(sys.argv[2]))
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=int(sys.argv[3]))
cand = [(n, s) for n, t, s in copy
        if n not in lake and not n.startswith("_prune/")
        and datetime.datetime.fromisoformat(t.replace("Z", "+00:00")) < cutoff]
gone = sum(1 for n, t, s in copy if n not in lake)
open(sys.argv[4], "w").write("".join(n + "\n" for n, s in cand))
print(f"lake: {len(lake)} objects | copy: {len(copy)} objects, {sum(s for _, _, s in copy) / 1e6:.1f} MB")
print(f"in the copy but no longer in the lake: {gone} (of which older than the cut-off: {len(cand)})")
print(f"candidates: {len(cand)} objects, {sum(s for _, s in cand) / 1e6:.1f} MB")
if copy and len(cand) > len(copy) / 2:
    print("REFUSED: more than half of the copy would go; check the lake listing first"); sys.exit(2)
PY
N=$(wc -l < "$TMP/candidates.txt" | tr -d ' ')
if [ "$N" -eq 0 ]; then echo "nothing to prune"; exit 0; fi
head -5 "$TMP/candidates.txt" | sed 's/^/  e.g. /'
if [ "$APPLY" != true ]; then echo "dry run: run again with --apply to delete these $N objects"; exit 0; fi
printf 'Delete %s objects from %s? Type the number to confirm: ' "$N" "$BUCKET"; read -r answer
[ "$answer" = "$N" ] || { echo "not confirmed; nothing deleted"; exit 1; }
deleted=0
while read -r name; do
  oci os object delete -ns "$NS" -bn "$BUCKET" --object-name "$name" --force >/dev/null && deleted=$((deleted + 1))
done < "$TMP/candidates.txt"
echo "deleted $deleted of $N objects"
