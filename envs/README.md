# Ambientes

Ajustes por cluster sobre a mesma plataforma (ADR-010). Por agora só documentam as diferenças; passam a
*overlays* (Kustomize / valores Helm por ambiente) quando a Oracle entrar.

| | `local` (Mac, Lima + k3s) | `oracle` (Always Free A1) |
|---|---|---|
| Recursos | 8 CPU / 16 GB | 2 OCPU / 12 GB |
| Execução | em série (igual à Oracle, para testar o orçamento) | em série (`max_active_runs=1`, pool do Airflow pequeno) |
| Segredo zero do ESO | chave API do utilizador `eso-reader` | *instance principal* (sem chave no cluster) |
| VM | `envs/local/lima/industrial.yaml`, `scripts/vm-start.sh` / `vm-stop.sh` | `terraform/oracle/` |
