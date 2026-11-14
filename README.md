# platform

Shared data platform (GitOps), delivered by Argo CD to each cluster: local (Mac, Lima + k3s) and Oracle Cloud
(Always Free, Ampere A1). Projects (code, DAGs, images) live in their own repositories; this one only says
**what runs, with which image, and in which environment**.

```
terraform/oracle/      the Oracle machine (VM, network) and the secrets vault
platform/              shared by every project
  argocd/              Argo CD, the root application and the per-project ApplicationSet
  airflow/             one Airflow for everyone (KubernetesExecutor)
  k8s/                 Postgres (+Timescale), SeaweedFS, lakeFS, namespaces
  openmetadata/        catalog, lineage and quality-gate history
projects/<project>/    one project = one folder (today: modbus)
envs/local · oracle    what differs between environments
scripts/               bootstrapping a new cluster and operating the local VM
```

**Bootstrapping a cluster** (the VM already exists: Lima locally, `terraform/oracle` on Oracle):

1. `scripts/install-argocd.sh`, then `kubectl apply -f envs/<local|oracle>/root-app.yaml`
2. locally only: `scripts/eso-local-key.sh` (the one key the External Secrets Operator needs; Oracle uses instance principal)
3. `scripts/wait-secrets.sh` (Argo CD installs the operator, which creates every Secret from the vault)
4. `scripts/bootstrap-postgres-ingest.sh`, `scripts/install-airflow.sh`, `scripts/install-openmetadata.sh`

**Secrets:** no secret value is stored in this repository. They live in a vault (OCI Vault) and the External
Secrets Operator creates the Kubernetes Secrets in each cluster.

First project: [modbus_data_plataform](https://github.com/elwarrior100/modbus_data_plataform), an industrial
pipeline Modbus RS-232 → OPC UA → lakeFS (bronze/silver/gold) with quality gates enforced by lakeFS hooks.
