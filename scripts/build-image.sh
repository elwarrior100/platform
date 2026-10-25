#!/usr/bin/env bash
# Constrói uma imagem dentro da VM Lima (podman) e importa-a no k3s.
# Uso: build-image.sh <pasta-com-Dockerfile> <nome:tag>
set -euo pipefail

CTX="${1:?pasta de contexto}"
IMAGE="${2:?nome:tag}"
VM="${LIMA_INSTANCE:-industrial}"
REMOTE="/tmp/build-$(basename "$IMAGE" | tr ':/' '--')"

limactl shell "$VM" -- command -v podman >/dev/null 2>&1 \
  || { limactl shell "$VM" -- sudo apt-get update -qq \
       && limactl shell "$VM" -- sudo apt-get install -y -qq podman >/dev/null; }

limactl shell "$VM" -- rm -rf "$REMOTE"
limactl shell "$VM" -- mkdir -p "$REMOTE"
tar -C "$CTX" --exclude=.venv --exclude=__pycache__ --exclude=.pytest_cache -cf - . \
  | limactl shell "$VM" -- tar -C "$REMOTE" -xf -

limactl shell "$VM" -- sudo podman build -t "localhost/$IMAGE" "$REMOTE"
limactl shell "$VM" -- sh -c "sudo podman save localhost/$IMAGE | sudo k3s ctr images import -"
echo "imagem localhost/$IMAGE disponível no k3s"
