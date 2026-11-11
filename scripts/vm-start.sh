#!/usr/bin/env bash
# Arranca a VM do cluster e volta a aceitar pods (desfaz o `cordon` feito por vm-stop.sh).
set -euo pipefail
VM="${LIMA_INSTANCE:-industrial}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"
limactl start "$VM"
for _ in $(seq 1 30); do kubectl get nodes >/dev/null 2>&1 && break; sleep 4; done
kubectl uncordon "$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
echo "A esperar pelos pods (PostgreSQL primeiro, depois lakeFS, ingestão e Airflow)…"
sleep 60
kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"{print "ainda a arrancar:", $1"/"$2, $4}' || true
echo "kernel da VM: $(limactl shell "$VM" -- uname -r)"
