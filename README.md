# platform

A **zero-cost data platform** for one person, run with GitOps. Argo CD delivers this repository to two Kubernetes
(k3s) clusters:
- **local**: a Lima VM on a Mac, where every change is tried first;
- **oracle**: one Oracle Cloud Always Free VM (Ampere A1, 2 OCPU / 12 GB), the production one.

Projects keep their code, DAGs and images in their own repositories. This repository only says **what runs, with
which image, in which environment, and how it is protected, backed up and kept free**.

First project: [modbus_data_plataform](https://github.com/elwarrior100/modbus_data_plataform), an industrial
pipeline Modbus RS-232 → OPC UA → lakeFS (bronze/silver), with quality gates enforced by lakeFS hooks. Its
`docs/adr/` holds the architecture decisions (ADRs) of this platform too.

## Contents
1. [Architecture at a glance](#architecture-at-a-glance)
2. [Repository layout](#repository-layout)
3. [Prerequisites](#prerequisites)
4. [Environments and promotion](#environments-and-promotion)
5. [Bootstrap: local cluster from zero](#bootstrap-local-cluster-from-zero)
6. [Bootstrap: Oracle from zero](#bootstrap-oracle-from-zero)
7. [Secrets](#secrets)
8. [Security model](#security-model)
9. [Day-to-day operation](#day-to-day-operation)
10. [Deploying a change or a new image](#deploying-a-change-or-a-new-image)
11. [Adding a project](#adding-a-project)
12. [Backups, restores and drills](#backups-restores-and-drills)
13. [Monitoring and alarms](#monitoring-and-alarms)
14. [Cost safety](#cost-safety)
15. [CI checks](#ci-checks)
16. [Script index](#script-index)
17. [Values to change when rebuilding or forking](#values-to-change-when-rebuilding-or-forking)
18. [Known limitations](#known-limitations)
19. [Further reading and glossary](#further-reading-and-glossary)

## Architecture at a glance
```
  Mac ── Tailscale (private network, no public port anywhere) ──────────────────────────┐
   │                                                                                    │
   ├─ Lima VM "industrial" (k3s)  ← follows branch main          Oracle VM agente-01 (k3s)  ← follows branch oracle
   │                                                              ├─ argocd        Argo CD (app-of-apps, ApplicationSet)
   │   same applications, local values                            ├─ data          Postgres+Timescale · SeaweedFS (S3) · lakeFS
   │                                                              ├─ airflow       Airflow (KubernetesExecutor)
   │                                                              ├─ openmetadata  OpenMetadata + OpenSearch
   │                                                              ├─ monitoring    Prometheus + Grafana
   │                                                              ├─ external-secrets  reads the OCI Vault
   │                                                              ├─ backup · ops  nightly backups, restore drill, checks,
   │                                                              │                cost guard (instance principal, no keys)
   │                                                              └─ ingest · ot   the modbus project
   │
   └─ terraform/oracle ──► Oracle Cloud: VM, firewall (no inbound port), OCI Vault, Object Storage (backups, lake
                           copy, Terraform state), 20 OCI alarms + email, budget, cost-guard IAM
```
Data path of the first project: OPC UA → collector → Postgres spool → writer → lakeFS bronze → Airflow silver (G2
gate) → lakeFS main. Backups leave the VM every night to Object Storage, and a daily drill restores them elsewhere.

## Repository layout
```
platform/              shared by every project and both environments
  argocd/              Argo CD values, its applications (apps/) and AppProjects (projects/)
  airflow/             Airflow values (one Airflow for everyone)
  monitoring/          Prometheus + Grafana values
  openmetadata/        OpenMetadata + OpenSearch values
  k8s/                 plain manifests: namespaces, Postgres, SeaweedFS, lakeFS, secrets (ExternalSecrets),
                       network policies, admission policies, the Airflow logs volume
projects/<project>/k8s/<component>/   one folder per component; the "projects" ApplicationSet deploys it
envs/local · envs/oracle              what differs per environment (root application, secret store, ingress;
                                      Oracle also: backup/, ops/, lakefs-gc/, bootstrap-vm.sh, Tailscale)
images/                images the platform builds itself (today: lakefs-gc), built and scanned by CI
terraform/oracle/      the Oracle side (README inside)
scripts/               bootstrap and operation (index below)
docs/runbook.md        what to do when something happens (alarms, restores, rebuilds)
.github/workflows/     CI: validate, images, bootstrap
```

## Prerequisites
- Tools: `kubectl`, `helm`, `terraform` 1.15, `oci` CLI, `tailscale`, `limactl` (local), `rclone`, `shellcheck`,
  `kubeconform`, `gitleaks` (for `make validate`).
- An OCI account with `~/.oci/config` (profile DEFAULT) and an SSH key at `~/.ssh/id_ed25519.pub`.
- A Tailscale tailnet; the Oracle VM joins it tagged `tag:platform` (policy copy: `envs/oracle/tailscale-policy.hujson`).
- **Every script defaults to the LOCAL cluster.** For Oracle, always `export KUBECONFIG=~/.kube/oracle.yaml` first;
  scripts print the cluster they are about to change.

## Environments and promotion
- **local** follows `main`; **oracle** follows the `oracle` branch (`envs/<env>/apps/kustomization.yaml` patches
  every application's revision).
- A change goes to `main`, runs on the local cluster, then `./scripts/promote-oracle.sh` fast-forwards `oracle` to it.
  It refuses anything that is not a fast-forward, not on `main`, or whose CI (`validate.yml`) is not green.
- Heavy changes (several JVMs restarting) are promoted one application at a time (runbook: "promote in small steps").
- `main` and `oracle` are protected on GitHub (no deletion, no force-push).

## Bootstrap: local cluster from zero
1. Lima VM with k3s: `limactl start --name industrial envs/local/lima/industrial.yaml` the first time, then
   `./scripts/vm-start.sh`. Always stop it with `./scripts/vm-stop.sh`, never by closing the Mac: an unclean stop
   corrupted lakeFS/SeaweedFS before.
2. `./scripts/install-argocd.sh`, then `kubectl apply -f envs/local/root-app.yaml`.
3. `./scripts/eso-local-key.sh` (the one key the External Secrets Operator needs locally), then `./scripts/wait-secrets.sh`.
4. `./scripts/bootstrap-postgres-ingest.sh`, `./scripts/bootstrap-postgres-serving.sh`, `./scripts/install-airflow.sh`, `./scripts/install-openmetadata.sh`
   (they create database roles; Argo CD installs the applications themselves).
5. `./scripts/lakefs-repo.sh industrial-lake lake` (the project's lakeFS repository, its protection and GC rules).
6. `./scripts/argocd-admin-password.sh`, `./scripts/openmetadata-admin-password.sh` (passwords from the vault).
7. `./scripts/ui.sh` to open the web UIs.

## Bootstrap: Oracle from zero
Read docs/runbook.md, "The VM is lost entirely", first: it lists the **cost traps** of a rebuild (an orphaned boot
volume, the cost-guard quota, the pinned private IP, the VM import). In short:
1. `terraform/oracle` (README inside): `terraform init -backend-config=backend.hcl`, read the plan (exactly one VM),
   `terraform apply`.
2. Join Tailscale from the OCI serial console (`tailscale up --advertise-tags=tag:platform --hostname=platform-oracle`),
   disable key expiry in the Tailscale console.
3. `./envs/oracle/bootstrap-vm.sh` (kubelet settings, swap, k3s, Tailscale Services; writes `~/.kube/oracle.yaml`).
4. `export KUBECONFIG=~/.kube/oracle.yaml`; `./scripts/install-argocd.sh`; `kubectl apply -f envs/oracle/root-app.yaml`;
   `./scripts/wait-secrets.sh` (Oracle reads the vault with the VM's instance principal: no key).
5. Restore the databases and the lake from the backups (runbook), then steps 4–6 of the local list as needed.

## Secrets
No secret value is in this repository, in Terraform state or in command arguments. They live in the **OCI Vault**
(`terraform/oracle/vault.tf`, DEFAULT vault, software keys: free), are seeded with `scripts/vault-seed.sh`, and the
**External Secrets Operator** creates the Kubernetes Secrets (`platform/k8s/secrets`). Vault names are
`<namespace>-<secret>`; an admission rule lets each namespace read only its own prefix. Read one with
`./scripts/vault-get.sh <secret> <field> | pbcopy`. Keep an offline copy: lakeFS's `AUTH_ENCRYPT_SECRET_KEY` is needed
to read a restored lakeFS database.

## Security model
- No inbound port open to the internet (`terraform/oracle/network.tf`); SSH and the web UIs go through Tailscale
  (`https://<airflow|grafana|argocd|lakefs|openmetadata>.taila669aa.ts.net`).
- Admission policies (`platform/k8s/admission`): no pod in a namespace without `platform/network-reviewed`; no
  privileged/hostPID/hostIPC/hostPath pods, added capabilities or debug containers outside kube-system; no hostNetwork;
  ExternalSecrets limited to their own vault prefix. Pod Security `baseline` on every namespace.
- Network policies: default-deny egress with allow-lists, ingress to the data services only from their clients, the
  cloud metadata endpoint (the VM's identity) reachable only by `external-secrets`, `backup` and `ops`.
- Argo CD AppProjects: a project deploys only into its own namespaces, from this repository, nothing cluster-wide.
- Least-privilege OCI IAM: the VM may create and read backups but never overwrite or delete them; the cost guard may
  create a quota but not lift it.

## Day-to-day operation
- Web UIs: `./scripts/ui.sh` (or the `*.ts.net` names); passwords from the vault.
- Local VM: `./scripts/vm-start.sh` / `./scripts/vm-stop.sh`.
- Something happened (an alarm email, a reboot, a crash loop): docs/runbook.md, organised by symptom.

## Deploying a change or a new image
- Manifests or values: edit, commit to `main`, check the local cluster, `./scripts/promote-oracle.sh`.
- New project code: the project's CI publishes an image tagged with its commit SHA; set that tag in
  `projects/<project>/k8s/...` and, for DAGs, `MODBUS_PIPELINES_IMAGE` and the DAG bundle `tracking_ref` in
  `platform/airflow/values.yaml` (the same commit, so code and DAGs never drift).

## Adding a project
`./scripts/new-project.sh <project> <component> [component ...]` scaffolds its AppProject, namespaces (with the
security labels), closed egress and `projects/<project>/k8s/<component>/`. Nothing is committed: review `git diff`,
then open the network it needs, add its secrets to the vault, its lakeFS repository, its DAGs.

## Backups, restores and drills
| What | When (UTC) | Where | Proof |
|---|---|---|---|
| `pg_dump` of every database + roles | 02:30 daily | bucket `platform-backups`, kept 7 days | `scripts/pg-restore-test.sh` |
| Lake objects, in bundles (ADR-016) | 03:00 daily, full weekly | bucket `platform-lake-backup`, kept 9 days | daily drill |
| Lake restore drill (MD5 of every object) | 04:15 daily | scratch services in one pod | `scripts/lake-restore-test.sh` |
| Boot volume backup | Sundays | OCI (max ~4, of 5 free) | — |
| lakeFS garbage collection | Sundays 05:00 | mark-only until a reviewed sweep | `scripts/lakefs-gc-sweep.sh` |

Uploads are single requests (no multipart: it needs a permission the VM deliberately lacks). Old objects are deleted
by Object Storage lifecycle rules, never by the VM.

## Monitoring and alarms
Prometheus + Grafana inside the cluster for the last hours; **OCI alarms outside the VM** for what must reach an inbox
even when the VM is down (`terraform/oracle/alarms.tf`): VM down, CPU, memory, disk, a heartbeat missing from any
job (backup, lake copy, drill, GC, silver, disk check, cost guard), silver hours missing or late, Object Storage size and
requests, and any Prometheus alert firing (there is no Alertmanager: `ops/node-health` forwards the count).

## Cost safety
Zero cost is a hard requirement on a pay-as-you-go account:
- everything sized inside Always Free (the A1 VM uses the whole free 2 OCPU / 12 GB; never raise it);
- budget alerts at the first cent and at a 5-cent forecast (`terraform/oracle/budget.tf`);
- **cost guard** (ADR-017): hourly, at EUR 1.00 in a month it zeroes the tenancy quotas and soft-stops the VM, never
  deleting anything; resume with `./scripts/cost-guard-resume.sh`;
- Object Storage: ~30 requests a day (50,000 free a month), lifecycle deletion, alarms at 12/15 GB.
The runbook's "Safeguards" table lists every guard.

## CI checks
- `validate.yml` (every push): gitleaks over the whole history, both environments rendered, kubeconform, Terraform
  fmt/validate, shellcheck, Trivy config scan, the bootstrap order, the GC-vs-dumps retention invariant; weekly, the
  Oracle service ranges used by the egress policies. **A red run blocks promotion.**
- `bootstrap.yml`: a fresh kind cluster bootstraps both environments exactly as documented.
- `images.yml`: builds and scans `images/*` on arm64; weekly re-scan of every deployed image.
- Locally: `make validate` runs the same checks.

## Script index
| Script | What it does |
|---|---|
| `install-argocd.sh` | install/upgrade Argo CD and create the `bootstrap` project |
| `eso-local-key.sh` | the External Secrets key of the local cluster |
| `wait-secrets.sh` | wait until every Secret came from the vault |
| `bootstrap-postgres-ingest.sh` | the `ingest` database and role (and the live path: TimescaleDB, schema `live`, role `grafana_live`) |
| `bootstrap-postgres-serving.sh` | the BI database `serving` and its role (gold releases, modbus ADR-022) |
| `install-airflow.sh` / `install-openmetadata.sh` | database roles (and OpenSearch sysctl); Argo CD installs the apps |
| `lakefs-repo.sh` | a project's lakeFS repository, branch protection, GC rules |
| `argocd-admin-password.sh` / `openmetadata-admin-password.sh` | admin passwords from the vault |
| `vault-seed.sh` / `vault-new-password.sh` / `vault-get.sh` | seed, create, read vault secrets |
| `seaweedfs-lake-reader.sh` | the read-only S3 identity of the lake copy |
| `promote-oracle.sh` | promote a green, tested commit to Oracle |
| `new-project.sh` | scaffold a project |
| `ui.sh` | tunnels to the web UIs |
| `vm-start.sh` / `vm-stop.sh` | start / cleanly stop the local VM |
| `pg-restore-test.sh` / `lake-restore-test.sh` | prove the database / lake backups restore |
| `lakefs-gc-sweep.sh` | delete exactly a reviewed GC mark |
| `lake-backup-prune.sh` | exceptional manual prune of the lake copy (normally lifecycle rules do it) |
| `cost-guard-resume.sh` | resume after the cost guard stopped the VM |
| `check-oci-cidrs.sh` | has Oracle changed the service ranges? (CI, weekly) |
| `deployed-images.sh` | every deployed image (CI re-scan) |
| `build-image.sh` | build an image inside the Lima VM (local experiments) |
| `argocd-repo-access.sh` | deploy key for a PRIVATE repository (not needed here) |
| `save-credentials.sh` | write a local note with the web UI users and passwords |
| `envs/oracle/bootstrap-vm.sh` | prepare the Oracle VM and install k3s |
| `envs/oracle/tailscale-services.sh` | the HTTPS names of the web UIs |

## Values to change when rebuilding or forking
- Tailscale IP `100.108.9.15` and tailnet `taila669aa`: `envs/oracle/ingress/ingresses.yaml`,
  `envs/oracle/apps/ingress.yaml`, `envs/oracle/tailscale-services.sh`, `scripts/ui.sh`, docs/runbook.md.
- Repository URL `github.com/elwarrior100/...`: Argo CD applications, `scripts/promote-oracle.sh` (CI API), workflows.
- Region `eu-madrid-1`: the OSN ranges in the backup/ops egress policies (`scripts/check-oci-cidrs.sh` checks them).
- `terraform/oracle/terraform.tfvars` (from the `.example`) and `backend.hcl`.

## Known limitations
- One node: a reliable single machine, not high availability; heavy restarts are promoted in steps.
- 2 OCPU / 12 GB: the whole free allowance; there is no room to grow the VM for free.
- lakeFS Community has a single (admin) user: no per-application lakeFS keys (ADR-008).
- No Alertmanager: Prometheus alerts reach the inbox through an OCI alarm on their count.
- The lakeFS GC is mark-only until a reviewed sweep; lakeFS metadata (commits) is never collected.

## Further reading and glossary
- docs/runbook.md: operations by symptom.
- ADRs and the plan: [modbus_data_plataform/docs](https://github.com/elwarrior100/modbus_data_plataform/tree/main/docs).

| Term | Meaning |
|---|---|
| App-of-apps | the root Argo CD application that creates all the others |
| ApplicationSet | generates one Argo CD application per `projects/<project>/k8s/<component>/` folder |
| Instance principal | the Oracle VM's own identity: jobs reach OCI without any stored key |
| OSN | Oracle Services Network: the OCI API ranges the egress policies allow |
| Bundle / catalog | the lake copy format: new objects packed in a tar.gz, and a list of which bundle holds each |
| Drill | the daily restore of the backups into scratch services, to prove they work |
| Bronze / silver | raw ingested data / cleaned hourly data, both in lakeFS |
| G1 / G2 | the quality gates on bronze batches and silver hours, enforced by lakeFS hooks |
| Cost guard | the kill-switch that stops the VM at EUR 1.00 a month |

License: MIT (see LICENSE).
