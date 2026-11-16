#!/usr/bin/env bash
# Prepares the Oracle VM (Always Free A1: 2 OCPU / 12 GB) and installs k3s. Idempotent.
# Run from the Mac, over Tailscale:  ./envs/oracle/bootstrap-vm.sh
# Then, for the HTTPS names of the web UIs: ./envs/oracle/tailscale-services.sh (Tailscale Services, docs/runbook.md).
# Afterwards the kubeconfig is at ~/.kube/oracle.yaml, pointing at https://platform-oracle:6443 (Tailscale only:
# the VM has no inbound port open to the internet, see terraform/oracle/network.tf).
set -euo pipefail
HOST="${ORACLE_HOST:-platform-oracle}"
K3S_VERSION="v1.36.5+k3s1"            # same as the local cluster

ssh -o BatchMode=yes "ubuntu@$HOST" "K3S_VERSION='$K3S_VERSION' HOST='$HOST' bash -s" <<'REMOTE'
set -euo pipefail
# 4 GB of swap: a safety margin for the OS on 12 GB (Kubernetes keeps pods off swap by default).
if ! swapon --show | grep -q /swapfile; then
  sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile >/dev/null && sudo swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swap.conf >/dev/null
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-opensearch.conf >/dev/null   # OpenSearch needs it
sudo sysctl --system >/dev/null

# Graceful node shutdown: on a reboot or an OCI maintenance stop, the kubelet holds the shutdown for up to 90 s and
# stops pods in order (normal pods first, then critical ones), so Postgres and SeaweedFS flush to disk. Without this,
# k3s (KillMode=process) lets systemd kill the containers mid-write: that corrupted lakeFS twice on the Mac.
# - Kubernetes 1.36 only accepts it in the kubelet config file (the --shutdown-grace-period flag is gone).
# - systemd-logind must allow a 90 s delay: Ubuntu's unattended-upgrades caps it at 30 s in a file that sorts after
#   99-*.conf, so ours is named zz-* to be read last.
sudo mkdir -p /etc/systemd/logind.conf.d /var/lib/rancher/k3s/agent/etc/kubelet.conf.d
printf '[Login]\nInhibitDelayMaxSec=120\n' | sudo tee /etc/systemd/logind.conf.d/zz-graceful-shutdown.conf >/dev/null
sudo systemctl restart systemd-logind
printf 'apiVersion: kubelet.config.k8s.io/v1beta1\nkind: KubeletConfiguration\nshutdownGracePeriod: 90s\nshutdownGracePeriodCriticalPods: 30s\n' \
  | sudo tee /var/lib/rancher/k3s/agent/etc/kubelet.conf.d/99-graceful-shutdown.conf >/dev/null

# Container images: unused ones are removed from 70% disk use (default 85%), and any image unused for 14 days goes
# anyway. Every upgrade leaves the old image behind: they had reached 23 GB on 2026-11-16.
printf 'apiVersion: kubelet.config.k8s.io/v1beta1\nkind: KubeletConfiguration\nimageGCHighThresholdPercent: 70\nimageGCLowThresholdPercent: 55\nimageMaximumGCAge: 336h\n' \
  | sudo tee /var/lib/rancher/k3s/agent/etc/kubelet.conf.d/97-image-gc.conf >/dev/null

# A slice of the 2 OCPU and 12 GB kept for k3s itself and the OS, outside every pod's reach. Without it, restarting
# several heavy pods at once starved k3s' own database (kine) until k3s exited (2026-11-15). The scheduler sees
# 250m CPU and 768Mi less; pod requests were trimmed to their measured use to fit.
printf 'apiVersion: kubelet.config.k8s.io/v1beta1\nkind: KubeletConfiguration\nsystemReserved:\n  cpu: 100m\n  memory: 384Mi\nkubeReserved:\n  cpu: 150m\n  memory: 384Mi\n' \
  | sudo tee /var/lib/rancher/k3s/agent/etc/kubelet.conf.d/98-reserved.conf >/dev/null

# Memory eviction by the kubelet (k3s sets only imagefs/nodefs thresholds, which switches the kubelet's memory default
# off): below 600Mi free for 1 min, or 300Mi at once, the kubelet evicts pods in order (QoS, then PriorityClass:
# platform-batch first, platform-data last) instead of leaving it to the kernel OOM killer, which ignores priority.
# A soft eviction gives pods up to 60 s to stop (without it: ~2 s, an unclean Postgres stop).
# Command-line flags (config.yaml) win over kubelet.conf.d drop-ins, so this lives here.
sudo mkdir -p /etc/rancher/k3s
printf 'kubelet-arg:\n  - "eviction-hard=memory.available<300Mi,imagefs.available<5%%,nodefs.available<5%%"\n  - "eviction-soft=memory.available<600Mi"\n  - "eviction-soft-grace-period=memory.available=1m"\n  - "eviction-max-pod-grace-period=60"\n' \
  | sudo tee /etc/rancher/k3s/config.yaml >/dev/null

# k3s, pinned. The API certificate also covers the Tailscale name and IP, so kubectl works from the Mac.
if ! command -v k3s >/dev/null || ! k3s --version | grep -q "$K3S_VERSION"; then
  TS_IP="$(tailscale ip -4)"
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server \
    --write-kubeconfig-mode 644 --tls-san "$HOST" --tls-san "$TS_IP" >/dev/null
fi
sudo systemctl restart k3s        # picks up config.yaml; pods keep running (KillMode=process)
for _ in $(seq 1 30); do sudo k3s kubectl get nodes 2>/dev/null | grep -q ' Ready' && break; sleep 5; done
echo "k3s: $(k3s --version | head -1) | swap: $(swapon --show --noheadings | awk '{print $3}') | kernel: $(uname -r)"
REMOTE

mkdir -p "$HOME/.kube"
ssh -o BatchMode=yes "ubuntu@$HOST" 'cat /etc/rancher/k3s/k3s.yaml' | sed "s#https://127.0.0.1:6443#https://$HOST:6443#" > "$HOME/.kube/oracle.yaml"
chmod 600 "$HOME/.kube/oracle.yaml"
KUBECONFIG="$HOME/.kube/oracle.yaml" kubectl get nodes -o wide

# HTTPS names (Tailscale Services): needs the VM tagged tag:platform in the console first (docs/runbook.md).
"$(dirname "$0")/tailscale-services.sh" || echo "HTTPS names not ready yet: tag the VM tag:platform, then run envs/oracle/tailscale-services.sh"
