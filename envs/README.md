# Environments

Per-cluster adjustments on top of the same platform. For now they only document the differences; they become
overlays (Kustomize / per-environment Helm values) when the Oracle cluster comes online.

| | `local` (Mac, Lima + k3s) | `oracle` (Always Free A1) |
|---|---|---|
| Resources | 8 CPU / 16 GB | 2 OCPU / 12 GB |
| Execution | serial (same as Oracle, to test the budget) | serial (`max_active_runs=1`, small Airflow pool) |
| ESO "secret zero" | API key of the `eso-reader` user | instance principal (no key in the cluster) |
| VM | `envs/local/lima/industrial.yaml`, `scripts/vm-start.sh` / `vm-stop.sh` | `terraform/oracle/` |
