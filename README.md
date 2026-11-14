# plataform

Plataforma de dados partilhada (GitOps), servida pelo Argo CD a cada cluster: local (Mac, Lima + k3s) e Oracle
Cloud (Always Free, Ampere A1). Os projetos (código, DAGs, imagens) vivem nos seus próprios repositórios;
aqui só se diz **o que corre, com que imagem e em que ambiente**.

```
terraform/oracle/      a máquina na Oracle (VM, rede) e o cofre de segredos
platform/              partilhado por todos os projetos
  argocd/              o Argo CD, a aplicação raiz e o ApplicationSet dos projetos
  airflow/             um Airflow para todos (KubernetesExecutor)
  k8s/                 Postgres (+Timescale), SeaweedFS, lakeFS, namespaces
  openmetadata/        catálogo, linhagem e histórico dos gates de qualidade
projects/<projeto>/    um projeto = uma pasta (hoje: modbus)
envs/local · oracle    o que muda entre ambientes
scripts/               arranque de um cluster novo e operação da VM local
```

**Segredos:** nenhum valor de segredo está neste repositório. Ficam num cofre (OCI Vault) e o External Secrets
Operator cria os Secrets do Kubernetes em cada cluster.

Primeiro projeto: [modbus_data_plataform](https://github.com/elwarrior100/modbus_data_plataform), um pipeline
industrial Modbus RS-232 → OPC UA → lakeFS (bronze/silver/gold) com gates de qualidade impostos por hooks.
