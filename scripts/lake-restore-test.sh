#!/usr/bin/env bash
# Runs the lake restore drill NOW (Oracle only) and shows its result. The drill itself is the CronJob
# ops/lake-restore-drill (envs/oracle/ops/lake-restore-drill.yaml, every day 04:15 UTC): it rebuilds lakeFS from the
# newest dump and the object copy inside one throw-away pod, and compares the MD5 of every object on main.
# Usage: KUBECONFIG=~/.kube/oracle.yaml ./scripts/lake-restore-test.sh
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:?set KUBECONFIG to the Oracle cluster}"
JOB="lake-drill-$(date +%Y%m%d-%H%M%S)"
kubectl -n ops create job "$JOB" --from=cronjob/lake-restore-drill >/dev/null
trap 'kubectl -n ops delete job "$JOB" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
echo "$JOB running (fetch, restore the database and the objects, scratch lakeFS, checksum of every object on main)..."
rc=1   # wait until the Job completes or fails; its own deadline is 20 minutes
for _ in $(seq 1 250); do
  st=$(kubectl -n ops get job "$JOB" -o jsonpath='{.status.succeeded}/{.status.failed}')
  case "$st" in 1/*) rc=0; break ;; */1) break ;; esac
  sleep 5
done
POD=$(kubectl -n ops get pod -l job-name="$JOB" -o name | head -1)
for c in fetch restore-db restore-objects check heartbeat; do kubectl -n ops logs "$POD" -c "$c" 2>/dev/null | grep -v NOTICE || true; done
exit $rc
