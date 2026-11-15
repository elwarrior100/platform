#!/usr/bin/env bash
# Deletes EXACTLY the objects of a lakeFS GC mark that a person has read (Oracle only), and nothing newly marked:
# a one-off Job from the lakefs-gc CronJob with GC_MARK_ID set (do_mark=false, mark_id=<id>, do_sweep=true).
# The mark id is in the log of a mark-only run:  kubectl -n data logs job/<lakefs-gc job> | grep 'Report summary'
#   ("run_id" there is the mark id). Usage: KUBECONFIG=~/.kube/oracle.yaml ./scripts/lakefs-gc-sweep.sh <mark id>
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:?set KUBECONFIG to the Oracle cluster}"
MARK="${1:?mark id (run_id of a reviewed mark-only report)}"
[[ "$MARK" =~ ^[a-z0-9]{10,40}$ ]] || { echo "that does not look like a mark id: $MARK" >&2; exit 1; }
JOB="lakefs-gc-sweep-$(date +%Y%m%d-%H%M%S)"
kubectl -n data get cronjob lakefs-gc -o json | python3 -c '
import json, sys
cj = json.load(sys.stdin); job, mark = sys.argv[1], sys.argv[2]
spec = cj["spec"]["jobTemplate"]["spec"]
for c in spec["template"]["spec"]["containers"]:
    c["env"] = [e for e in c["env"] if e["name"] not in ("GC_MARK_ID",)] + [{"name": "GC_MARK_ID", "value": mark}]
print(json.dumps({"apiVersion": "batch/v1", "kind": "Job",
                  "metadata": {"name": job, "namespace": "data", "labels": {"app": "lakefs-gc", "gc-mode": "sweep-reviewed"}},
                  "spec": spec}))' "$JOB" "$MARK" | kubectl create -f - >/dev/null
echo "$JOB started: sweeping mark $MARK only. Follow it: kubectl -n data logs -f job/$JOB"
