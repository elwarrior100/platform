#!/usr/bin/env bash
# Deletes EXACTLY the objects of a lakeFS GC mark that a person has read (Oracle only), and nothing newly marked:
# a one-off Job from the lakefs-gc CronJob with GC_MARK_ID set (do_mark=false, mark_id=<id>, do_sweep=true).
#   1. finds the mark's report in the lakefs-gc Job logs and refuses a mark older than 48 h (a branch created since
#      could need objects it marked)
#   2. shows the list: reads the mark's parquet files (…/_lakefs/retention/gc/unified/<mark>/deleted/) through a
#      port-forward to SeaweedFS with the READ-ONLY lake key (backup-seaweedfs-reader), on this Mac
#   3. asks you to type "sweep", then starts the Job
# The mark id is the run_id in:  kubectl -n data logs job/<lakefs-gc job> | grep 'Report summary'
# Usage: KUBECONFIG=~/.kube/oracle.yaml ./scripts/lakefs-gc-sweep.sh <mark id>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:?set KUBECONFIG to the Oracle cluster}"
MARK="${1:?mark id (run_id of a reviewed mark-only report)}"
[[ "$MARK" =~ ^[a-z0-9]{10,40}$ ]] || { echo "that does not look like a mark id: $MARK" >&2; exit 1; }
TMP="$(mktemp -d)"; chmod 700 "$TMP"; PF=""
trap '[ -n "$PF" ] && kill "$PF" 2>/dev/null; rm -rf "$TMP"' EXIT

echo "1/3 the mark's report"
REPORT=""
for job in $(kubectl -n data get jobs -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  line=$(kubectl -n data logs "job/$job" 2>/dev/null | grep -o "Report summary=.*\"run_id\":\"$MARK\".*" || true)
  [ -n "$line" ] && { REPORT="${line#Report summary=}"; break; }
done
[ -n "$REPORT" ] || { echo "no lakefs-gc Job log has mark $MARK (Jobs are kept a week); run a mark first" >&2; exit 1; }
python3 - "$REPORT" <<'PY'
import datetime, json, sys
r = json.loads(sys.argv[1])
start = datetime.datetime.fromisoformat(r["start_time"].replace("Z", "+00:00")[:26] + "+00:00")
age = (datetime.datetime.now(datetime.timezone.utc) - start).total_seconds() / 3600
print(f"   mark {r['run_id']}: success={r['success']}, objects marked={r.get('num_deleted_objects')}, {age:.0f} h old")
if not r["success"]: sys.exit("   REFUSED: that mark run did not succeed")
if age > 48: sys.exit("   REFUSED: older than 48 h; run a fresh mark and review that one")
PY

echo "2/3 what it would delete (read-only key, through a port-forward)"
kubectl -n data port-forward pod/seaweedfs-0 18333:8333 >/dev/null 2>&1 & PF=$!
sleep 3
AK="$("$ROOT/scripts/vault-get.sh" backup-seaweedfs-reader S3_ACCESS_KEY)"
SK="$("$ROOT/scripts/vault-get.sh" backup-seaweedfs-reader S3_SECRET_KEY)"
AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" uv run -q --with boto3 --with pyarrow python - "$MARK" <<'PY'
import io, sys, boto3, pyarrow.parquet as pq
mark = sys.argv[1]
s3 = boto3.client("s3", endpoint_url="http://127.0.0.1:18333", region_name="us-east-1")
prefix = f"_lakefs/retention/gc/unified/{mark}/deleted/"
keys = [o["Key"] for p in s3.get_paginator("list_objects_v2").paginate(Bucket="lake", Prefix=prefix)
        for o in p.get("Contents", []) if o["Key"].endswith(".parquet")]
rows = []
for k in keys:
    t = pq.read_table(io.BytesIO(s3.get_object(Bucket="lake", Key=k)["Body"].read()))
    rows += t.to_pylist()
print(f"   {len(rows)} objects in the mark ({len(keys)} parquet files under lake/{prefix})")
for r in rows[:20]:
    print("   ", {k: v for k, v in r.items() if v is not None})
if len(rows) > 20: print(f"    … and {len(rows) - 20} more")
PY
unset AK SK

printf '3/3 Type "sweep" to delete exactly these objects: '; read -r answer
[ "$answer" = sweep ] || { echo "not confirmed; nothing deleted"; exit 1; }
JOB="lakefs-gc-sweep-$(date +%Y%m%d-%H%M%S)"
kubectl -n data get cronjob lakefs-gc -o json | python3 -c '
import json, sys
cj = json.load(sys.stdin); job, mark = sys.argv[1], sys.argv[2]
spec = cj["spec"]["jobTemplate"]["spec"]
for c in spec["template"]["spec"]["containers"]:
    c["env"] = [e for e in c["env"] if e["name"] != "GC_MARK_ID"] + [{"name": "GC_MARK_ID", "value": mark}]
print(json.dumps({"apiVersion": "batch/v1", "kind": "Job",
                  "metadata": {"name": job, "namespace": "data", "labels": {"app": "lakefs-gc", "gc-mode": "sweep-reviewed"}},
                  "spec": spec}))' "$JOB" "$MARK" | kubectl create -f - >/dev/null
echo "$JOB started: sweeping mark $MARK only. Follow it: kubectl -n data logs -f job/$JOB"
