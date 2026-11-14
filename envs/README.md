# Environments

The same platform runs in two clusters. Each `envs/<env>/apps` is a Kustomization: the shared applications
(`platform/argocd/apps`) plus that environment's own, and Oracle is patched to follow the `oracle` branch.

| | `local` (Mac, Lima + k3s) | `oracle` (Always Free A1) |
|---|---|---|
| Role | development: changes land here first | always on: promoted changes only |
| Git branch Argo CD follows | `main` | `oracle` (`scripts/promote-oracle.sh`) |
| Resources | 8 CPU / 16 GB | 2 OCPU / 12 GB |
| Execution | serial (same as Oracle, to test the budget) | serial (`max_active_runs=1`, `parallelism=2`) |
| ESO "secret zero" | API key of the `eso-reader` user (`scripts/eso-local-key.sh`) | instance principal (no key in the cluster) |
| Own applications | `secret-store` | `secret-store`, `backup` (nightly pg_dump to Object Storage) |
| Per-environment secrets | `platform-argocd-admin-local`, `openmetadata-admin-local` | `platform-argocd-admin-oracle`, `openmetadata-admin-oracle` |
| VM | `envs/local/lima/industrial.yaml`, `scripts/vm-start.sh` / `vm-stop.sh` | `terraform/oracle/`, `envs/oracle/bootstrap-vm.sh` |
| Shutdown | drain first (`vm-stop.sh`) | kubelet graceful shutdown (90 s), proved with a reboot |
