#!/usr/bin/env bash
# Pára a VM do cluster SEM perder dados. Usar sempre antes de fechar o Mac ou a app.
#
# Porquê não basta `limactl stop`: o k3s corre com KillMode=process, por isso ao parar a VM os contentores
# não recebem um pedido de encerramento gracioso e o PostgreSQL/SeaweedFS podem perder os últimos segundos
# (já aconteceu duas vezes: ver docs/adr/008-gates-e-imposicao.md). O `drain` pede a cada pod que termine
# (SIGTERM, com tempo para gravar) e só depois se pára a VM.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"
VM="${LIMA_INSTANCE:-industrial}"
NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"

echo "1/3 a esvaziar o nó (os pods terminam com graça)…"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force --grace-period=60 --timeout=240s

echo "2/3 a garantir que o PostgreSQL e o SeaweedFS já não correm…"
for _ in $(seq 1 30); do
  left="$(kubectl -n data get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [ "$left" = "0" ] && break
  sleep 3
done
limactl shell "$VM" -- sync

echo "3/3 a parar a VM…"
limactl stop "$VM"
echo "VM parada de forma limpa. Para voltar: ./scripts/vm-start.sh"
