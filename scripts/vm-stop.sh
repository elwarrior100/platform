#!/usr/bin/env bash
# Stops the cluster VM WITHOUT losing data. Always use it before closing the Mac or the app.
#
# Why `limactl stop` is not enough: k3s runs with KillMode=process, so when the VM stops the containers
# get no graceful shutdown and PostgreSQL/SeaweedFS can lose their last seconds of writes
# (it happened twice: see modbus_data_plataform docs/adr/008). `drain` asks every pod to terminate
# (SIGTERM, with time to flush) and only then is the VM stopped.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"
VM="${LIMA_INSTANCE:-industrial}"
NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"

echo "1/3 draining the node (pods terminate gracefully)…"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force --grace-period=60 --timeout=240s

echo "2/3 making sure PostgreSQL and SeaweedFS are no longer running…"
for _ in $(seq 1 30); do
  left="$(kubectl -n data get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [ "$left" = "0" ] && break
  sleep 3
done
limactl shell "$VM" -- sync

echo "3/3 stopping the VM…"
limactl stop "$VM"
echo "VM stopped cleanly. To start again: ./scripts/vm-start.sh"
