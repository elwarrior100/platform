#!/usr/bin/env bash
# Starts the cluster VM and accepts pods again (undoes the `cordon` done by vm-stop.sh).
set -euo pipefail
VM="${LIMA_INSTANCE:-industrial}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"
limactl start "$VM"
for _ in $(seq 1 30); do kubectl get nodes >/dev/null 2>&1 && break; sleep 4; done
kubectl uncordon "$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
echo "Waiting for pods (PostgreSQL first, then lakeFS, ingest and Airflow)…"
sleep 60
kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"{print "still starting:", $1"/"$2, $4}' || true
echo "VM kernel: $(limactl shell "$VM" -- uname -r)"
