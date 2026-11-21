# Runbook: what to do when

Every command assumes `KUBECONFIG` points at the right cluster (`~/.kube/oracle.yaml` for Oracle; the scripts default
to the local Lima cluster).

## Deploy a change
1. Commit to `main`. The local cluster applies it (Argo CD, ~3 min).
2. Check it there: `kubectl -n argocd get applications` (all Synced/Healthy) and the thing you changed.
3. Promote it to Oracle: `./scripts/promote-oracle.sh` (fast-forwards the `oracle` branch; refuses anything else).

## Deploy new project code (images)
1. The project's CI publishes `ghcr.io/elwarrior100/modbus-*:<sha>` (tests and a Trivy scan must pass).
2. In this repository, set that SHA in `projects/modbus/k8s/*` (ingest, ot) and, for the pipelines, in
   `platform/airflow/values.yaml` (both `MODBUS_PIPELINES_IMAGE` and the DAG bundle `tracking_ref`, in one commit).
3. Deploy as above (local first, then promote).

## The Oracle VM rebooted
- Nothing to do in principle: the kubelet stops pods gracefully (90 s) and everything comes back.
- Check: `kubectl get pods -A` (old pods show `Error`: they are the ones stopped by the shutdown; delete them with
  `kubectl delete pods -A --field-selector=status.phase=Failed`), Postgres log says `database system was shut down`
  (clean), the writer logs `exportado` again.

## The Airflow scheduler crash-loops after a reboot (seen with Airflow 3.2.2)
Symptom: `airflow-scheduler` in CrashLoopBackOff, log ends in `adopt_or_reset_orphaned_tasks` ...
`DetachedInstanceError`. Cause: a task was running when the node stopped; on start the scheduler tries to adopt that
orphan and crashes while logging it.
1. Find it: in the airflow database, `select run_id, task_id from task_instance where state = 'running'` whose
   `queued_by_job_id` is a failed scheduler job.
2. Mark it failed through the API (the CLI `tasks clear` does not touch a "running" task):
   `PATCH /api/v2/dags/<dag>/dagRuns/<run>/taskInstances/<task>` with `{"new_state": "failed"}` (admin login from the
   `airflow-admin` Secret), or "Mark as failed" in the UI if the API server is up.
3. Delete the scheduler pod; then `airflow tasks clear` that hour so it runs again.
Seen on 2026-11-14 after the graceful-shutdown reboot test. Check newer Airflow releases for a fix.

## lakeFS main is unreadable (a commit points at a missing object)
Every script defaults to the LOCAL cluster: export `KUBECONFIG=~/.kube/oracle.yaml` first when this is Oracle.
1. Stop new writes: `kubectl -n ingest scale deploy/writer --replicas=0`; pause `silver_hourly` in Airflow.
2. Find the last readable commit of `main` (lakeFS UI, commits of `main`: open the newest ones until a file reads).
   Note its time T: every merge after it will be dropped.
3. Remove `main`'s branch protection (lakeFS UI: repository settings, branches), then hard-reset it:
   `PUT /api/v1/repositories/industrial-lake/branches/main/hard_reset?ref=<commit id>` (lakeFS API hardResetBranch) (admin key, port-forward to
   `svc/lakefs` 8000). `scripts/lakefs-repo.sh` does NOT reset anything: it only re-creates the protection, so run it
   afterwards (`./scripts/lakefs-repo.sh industrial-lake lake`).
4. Re-export what was dropped: batches exported after T are still in the spool if newer than 7 days (spool retention).
   Set them back to pending, e.g. `UPDATE batches SET state='pending' WHERE state='exported' AND seq > <seq of the
   first batch after T>;` (find it from the batch ids in the dropped commits' metadata). Older batches are no longer
   in the spool: re-merge their `etl-*` branch if it still exists (pruned after 7 days), else restore the lake
   (section "Restore the lake").
5. Scale the writer to 1, unpause silver; the "silver hours missing or late" alarm lists the hours to re-run (clear
   them in Airflow; delete a leftover `silver-<dt>-<hh>` branch first). Then reconcile (project: `tests/phase3/run.sh`).

## The VM is lost entirely (rebuild from git + Terraform + backups)
Order matters; every step is from the repositories, the vault and Object Storage. Nothing on the old disk is needed.
1. `cd terraform/oracle && terraform apply`: a new VM (new OCID; the dynamic group, its policies and the alarms
   follow it). It has no open port (network.tf), so the first login is through the OCI console: instance, "Console
   connection" (serial console), or Cloud Shell with a temporary security-list rule for port 22 from Cloud Shell's
   address, removed right after.
2. On the VM: install Tailscale and join with a one-time auth key from the Tailscale admin console, tagged
   `tag:platform` (`sudo tailscale up --auth-key=... --advertise-tags=tag:platform --hostname=platform-oracle`). In
   the console, disable key expiry for it. Its Tailscale IP changes: update `100.108.9.15` in
   `envs/oracle/ingress/ingresses.yaml`, `envs/oracle/apps/ingress.yaml`, `scripts/ui.sh` and this runbook (grep for it).
3. From the Mac: `./envs/oracle/bootstrap-vm.sh` (kubelet settings, swap, k3s, Tailscale Services), then
   `export KUBECONFIG=~/.kube/oracle.yaml` for EVERY step below (the scripts default to the local cluster).
4. `./scripts/install-argocd.sh`, `kubectl apply -f envs/oracle/root-app.yaml`, `./scripts/wait-secrets.sh` (the
   External Secrets Operator reads the vault with the new instance principal).
5. `./scripts/bootstrap-postgres-ingest.sh`; restore the databases from the newest COMPLETE dump (`_COMPLETE`):
   `globals.sql` first (roles), then `pg_restore --create -d postgres` per database (`--create`: the databases do not
   exist yet), then restart lakeFS, Airflow, OpenMetadata.
6. Restore the lake objects (section "Restore the lake"), BEFORE starting the writer.
7. `./scripts/install-airflow.sh` / `install-openmetadata.sh` only if their applications are not healthy; then the
   writer and the DAGs. Check every alarm returns to OK.
Cost traps in a rebuild (zero cost: check each before `terraform apply`):
- The lost VM's boot volume is KEPT by default when an instance is terminated in the console. Old 100 GB + new 100 GB
  is exactly the free 200 GB, with no room left: delete the orphan (or reuse it as the new boot volume, or restore
  from the weekly backup) before creating the new VM.
- The cost guard runs ON the VM: while it is down there is no automatic kill-switch, only the budget emails.
- If the cost guard had tripped, the quota `cost-guard-zero` zeroes compute and block storage and the new VM cannot be
  created: run `scripts/cost-guard-resume.sh` first.
- `imports.tf` adopts the VM in `instance_ocid`: with the VM gone, point it at nothing (remove that import block for
  the rebuild only) and READ the plan: it must create exactly one instance. Never `apply` a plan with two.
- The private IP 10.0.0.43 is pinned (main.tf): if the old VM still exists (stopped, not terminated), the new one
  cannot take it. Terminate the old one first.

If the vault itself is lost, the Secrets cannot be recreated: lakeFS's `AUTH_ENCRYPT_SECRET_KEY` in particular is
needed to read the restored lakeFS database. Keep an offline copy of the vault secrets (`scripts/vault-get.sh`) in a
password manager.

## An alarm email arrived (OCI Notifications, topic platform-alerts)
| Alarm | First look |
|---|---|
| VM not reporting | `ssh ubuntu@platform-oracle`; if no answer, OCI console: instance state, serial console |
| CPU > 90% / memory > 92% | Grafana (`http://grafana.100.108.9.15.sslip.io`, or `./scripts/ui.sh` :3000), "Kubernetes / Compute Resources / Namespace"; `kubectl top pods -A` |
| no successful backup in 24 h | `kubectl -n backup get jobs`; logs of the newest `pg-backup` job |
| no successful lake copy in 24 h | `kubectl -n backup get jobs`; logs of the newest `lake-sync` job (a listing error of the copy fails the night on purpose, instead of a silent full bundle) |
| lake restore drill missing / failed | `kubectl -n ops get jobs`; logs of the newest `lake-restore-drill` job (containers `restore-objects`, `check`) |
| lakeFS GC failed / check missing | `kubectl -n data get jobs`; logs of the newest `lakefs-gc` job; `kubectl -n ops logs` of the last gc-freshness job |
| silver not updated for 3 h | Airflow `silver_hourly` runs (a G2 fail is expected for incomplete hours); writer logs; `kubectl -n ops logs` of the last freshness job |
| disk above 80% / disk check missing | `ssh` the VM: `df -h /`, `sudo k3s crictl rmi --prune`; `kubectl -n ops get jobs` (node-health) |
| Prometheus alerts firing | which ones: lines `firing:` in the logs of the newest `ops/node-health` job; then that alert's runbook link in Prometheus /alerts |
| bucket above N GB / all Object Storage above 15 GB | `oci os object list` on the bucket; dumps expire after 7 days, lake bundles and catalogs after 9 days: growth here means the lake itself grew (retention/GC, ADR-015) |
| Object Storage requests above 1,500 in a day | who made them: the lake copy should make ~6 a night, the drill a few a day; a manual prune or restore is expected to trip it (ADR-016) |
| cost guard: COST LIMIT / not running | section "Cost kill-switch tripped" below; "not running": `kubectl -n ops logs` of the newest `cost-guard` job |

## A new job pod cannot connect for its first seconds
kube-router adds a new pod to the network-policy allow-lists a few seconds after it starts. Jobs must retry their
first connection (pg-backup waits for `pg_isready`). Symptom: "Connection refused" that disappears on a retry.

## Restore the lake (lakeFS metadata + objects)
It is drilled every day at 04:15 UTC (`ops/lake-restore-drill`: rebuilds lakeFS from the newest dump and the object
copy inside one throw-away pod, compares the MD5 of every object on `main`; alarm after 2 days without a pass).
Run it now, without touching anything live: `KUBECONFIG=~/.kube/oracle.yaml ./scripts/lake-restore-test.sh`. The real restore:
1. Stop writers: scale `ingest/writer` and pause the Airflow DAGs.
2. Objects: the copy is in bundles (ADR-016), not object by object. Take the first catalog in
   `platform-lake-backup/catalog/` written AFTER the dump you restore (the drill uses the newest, always after the
   02:30 dump); its second column lists the bundles; `rclone cat` each bundle `| tar -xz` into a staging volume, then
   `rclone move` the staging volume into `lake:lake`. The exact commands are the `restore-objects` container of
   `envs/oracle/ops/lake-restore-drill.yaml` (it does this daily into a scratch SeaweedFS). Run it from a pod in the
   `backup` namespace labelled `app: lake-sync` (SeaweedFS only accepts the lake copy and lakeFS), with the admin key
   of `data-seaweedfs-auth` in a temporary Secret deleted afterwards (the backup key is read-only). Size the staging
   volume at about the size of the lake (the drill uses 20 Gi).
3. Metadata: restore the `lakefs` database from the newest complete dump (see below), then restart lakeFS.
4. Check: list `main` in lakeFS and read a bronze and a silver file; reconcile the spool (project: tests/phase3/run.sh).

## Restore a database
- Backups: `platform-backups/<date>/<HHMMSS>/` in Object Storage (one prefix per run, nightly, kept 7 days); a run
  is complete only if it has `_COMPLETE` (written last). The lake objects are copied nightly to `platform-lake-backup`. Prove they restore at any time:
  `./scripts/pg-restore-test.sh` (restores into scratch databases and compares row counts).
- Real restore: scale the application to 0, `pg_restore --clean -d <db>` from the dump (same image as Postgres),
  scale back up.

## A password must change
1. New version of the secret in the OCI Vault (console, or `oci vault secret update-base64`).
2. If it is a Postgres role: `ensure_pg_role` (scripts/lib.sh) with the new value, on each cluster.
3. The External Secrets Operator refreshes the Secret within 1 h (or annotate the ExternalSecret to force it).
4. Restart the pods that read it at startup.

## Where are the passwords?
`./scripts/vault-get.sh <secret> <field> | pbcopy`, e.g. `platform-argocd-admin-oracle password`,
`openmetadata-admin-oracle password`. Never in git, never printed.

## Oracle changed its service addresses
The backup and ops jobs may only reach the Oracle Services Network ranges of eu-madrid-1. `validate.yml` runs
`./scripts/check-oci-cidrs.sh` every Monday; if it fails (or the backup alarms fire with "connection timed out"),
copy the `+` lines it prints into the `oci-osn-cidrs` block of both egress policies and promote.

## A new project
`./scripts/new-project.sh <project> <component> [component ...]` scaffolds it (nothing committed): its Argo CD project
(only its namespaces), one namespace per component with the security labels, closed egress (DNS and itself), and
`projects/<project>/k8s/<component>/` for the manifests, which the projects ApplicationSet picks up. It then lists the
deliberate steps: secrets (vault + ClusterSecretStore conditions), opening the network it needs, the lakeFS
repository, DAGs. Review `git diff`, commit, check the local cluster, promote.

## A new namespace
Pods are refused until the namespace has the label `platform/network-reviewed` (admission rule
network-reviewed-namespaces). First write its NetworkPolicies (at least `deny-cloud-metadata`, see
`platform/k8s/network-policies`), then add the namespace to `platform/k8s/00-namespaces.yaml` with the label and a
comment saying which policy applies.

## SeaweedFS (storage emergencies only)
Not in the browser and not in `ui.sh`, on purpose: the filer has no login and can delete lake objects behind lakeFS'
back (no gates, no commit, no history). To look at the lake objects use lakeFS. For the storage itself:
```
kubectl -n data exec -it seaweedfs-0 -- weed shell
> s3.bucket.list            # buckets and their size
> fs.du /buckets/lake       # size of the lake bucket
> volume.list               # volumes and free space
```
Read-only commands only. Anything that writes or deletes here (`fs.rm`, `volume.delete`...) bypasses lakeFS:
restore from the backups instead (section "Restore the lake").

## Large changes on Oracle: promote in small steps
2 OCPU cannot restart many heavy pods at once. On 2026-11-15 pinning every chart image by digest restarted OpenSearch,
OpenMetadata, Prometheus, Grafana and Argo CD together: load reached 14, k3s' own database (kine) became too slow and
k3s exited ("Transaction commit failed"); systemd restarted it and everything recovered in ~5 min, data intact.
For changes that restart several heavy workloads, promote one application at a time (or refresh them one by one) and
wait for the load (`uptime` on the VM) to fall below ~3 before the next.

## The lake copy cleans itself (no monthly prune)
The lake copy is in bundles (ADR-016): a full one when the newest full is 7 days old, small incremental ones nightly,
a catalog each time. The VM can never delete there (that makes the copy tamper-proof); Object Storage itself deletes
`bundles/` and `catalog/` older than 9 days (lifecycle rule in terraform/oracle/backups.tf), so a restore (newest full
+ the incrementals after it) always finds what it needs, and the copy stays at about 2.5x the lake.
`./scripts/lake-backup-prune.sh` remains for an exceptional manual prune only (dry run by default; every deletion is
one request, `--max` caps a run). The `objectstorage_requests_high` alarm warns when a day goes over 1,500 requests;
`storage_high` when the copy passes 12 GB, `storage_total_high` when all Object Storage passes 15 GB.

## HTTPS names (Tailscale Services on the VM)
`https://<airflow|grafana|argocd|lakefs|openmetadata>.taila669aa.ts.net`: one Tailscale Service per UI, served by the
VM (tagged `tag:platform`) with a Let's Encrypt certificate and handed to Traefik on 127.0.0.1:80; the Ingresses also
answer these names. Check or (re)configure: `./envs/oracle/tailscale-services.sh [--check]`. A rebuilt VM needs:
the tailnet policy as in `envs/oracle/tailscale-policy.hujson` (a copy of the console's; paste it back if lost), the
machine re-tagged `tag:platform`, the five Services defined (listed at the end of that file), then the script once. The sslip.io names and
`ui.sh` remain the fallback. No Kubernetes operator on purpose: its proxies run privileged (ADR-014).

## lakeFS garbage collection
Weekly CronJob `data/lakefs-gc` (Sundays 05:00 UTC, Oracle only), mark only (`GC_SWEEP=false`) until a person has
read a report. Heartbeat: `ops/gc-freshness` posts `lake_gc_success` daily (alarms: 0, or nothing for 2 days).
1. Read the report: `kubectl -n data logs job/<latest lakefs-gc job> | grep 'Report summary'`
   (`run_id` = the mark id, `num_deleted_objects` = how many it would delete).
2. First real deletion, of exactly that list: `KUBECONFIG=~/.kube/oracle.yaml ./scripts/lakefs-gc-sweep.sh <mark id>`.
   It refuses a mark older than 48 h, prints the marked objects (read-only key) and asks you to type `sweep`.
3. Once that went well, set `GC_SWEEP: "true"` in `envs/oracle/lakefs-gc/gc.yaml` (weekly mark and sweep).
GC retention (15 days, `scripts/lakefs-repo.sh`) must stay >= the dump lifecycle (7 days): CI checks it.

## CPU and memory headroom (2 OCPU, 12 GB)
The kubelet reserves 250m CPU and 768Mi for k3s and the OS (`kubelet.conf.d/98-reserved.conf`, bootstrap-vm.sh):
pods see 1.75 CPU. Requests follow measured use (`kubectl top pods -A`); heavy JVMs (OpenMetadata, OpenSearch) and
Prometheus have CPU limits. Re-runnable batch jobs (GC, drill) use PriorityClass `platform-batch`. Memory eviction by the kubelet (k3s
`config.yaml`: soft 600Mi for 1 min, hard 300Mi) evicts pods over their requests first, then by priority; the kernel
OOM killer (QoS-based, priority-blind) only acts if memory runs out faster than that.

## Zero cost: a budget alert arrived
Zero cost is a hard requirement. The tenancy budget (terraform/oracle/budget.tf) emails on ANY charge (EUR 0.01) and
on a forecast over EUR 0.05. When it fires:
1. Cost by service this month (read-only):
   `oci usage-api usage-summary request-summarized-usages --tenant-id <tenancy> --time-usage-started <1st of month>
   --time-usage-ended <tomorrow> --granularity DAILY --query-type COST --group-by '["service","skuName"]'`
2. Usual suspects and their free limits: Object Storage requests (50,000/month: the lake copy must stay in bundles,
   ADR-016) and storage (20 GB); block storage (200 GB incl. the boot volume, 5 volume backups); A1 compute (Always Free:
   2 OCPU / 12 GB in total, which this VM already uses entirely: never raise `ocpus`/`memory_in_gbs`); Vault (software keys only; never a virtual private vault); load balancers and reserved IPs (none).
3. Stop the source first (suspend the CronJob in git, promote), then fix the design, then re-enable.

## Cost kill-switch tripped (VM stopped on purpose)
The hourly guard (envs/oracle/ops/cost-guard.yaml, ADR-017) found the month's spend at EUR 1.00 or more: it created the
tenancy quota `cost-guard-zero` (nothing paid can be created) and soft-stopped the VM. Nothing was deleted.
1. Find the cause first: cost by service (command in the section above). Fix it in git before resuming, or the jobs
   that caused it run again when the VM starts (suspend the CronJob, promote after the VM is up).
2. Resume from the Mac: `./scripts/cost-guard-resume.sh --dry-run`, then without `--dry-run`. It deletes the quota,
   tags the VM `cost-guard-ack=<YYYY-MM>` (the guard only reports for the rest of that month) and starts the VM.
3. After ~3 minutes: `ssh ubuntu@platform-oracle 'sudo k3s kubectl get nodes'`, then the Argo CD apps healthy.
**Resume within 9 days.** Object Storage lifecycle rules keep running while the VM is off: lake bundles and catalogs
go after 9 days and dumps after 7, and with the VM stopped no new ones are written. Past 9 days the off-site lake copy
is gone (the lake on the VM disk is intact); the first night after resuming writes a full bundle again.
Testing the guard without acting: render the CronJob as a Job with THRESHOLD=0.001 and DRY_RUN=true (it prints
"DRY RUN: would create quota ... and SOFTSTOP"). Never test with DRY_RUN=false: it stops the VM.

## Safeguards: nothing fills up, nothing costs (all email the alert address)
| Risk | Guard |
|---|---|
| Any charge on the tenancy | budget alert at EUR 0.01 actual, EUR 0.05 forecast (budget.tf) |
| A runaway charge | ops/cost-guard hourly: at EUR 1.00 in the month, zero quotas + soft-stop the VM, never deletes (ADR-017); alarms when tripped and when the guard stops |
| Object Storage requests (50k free/month) | lake copy in bundles (ADR-016); alarm above 1,500 requests in a day |
| Object Storage space (20 GB free) | alarms at 12 GB (lake copy), 5 GB (dumps) and 15 GB (all buckets); dumps expire after 7 days, lake bundles and catalogs after 9 days |
| Spool (Postgres) growth | ingest/spool-retention daily: events of exported batches older than 7 days, rejected ones older than 30 |
| VM disk | ops/node-health every 30 min, alarm above 80% and when the check stops; kubelet image GC from 70% and after 14 days unused; kubelet evicts pods at 95% |
| VM memory | OCI MemoryUtilization alarm above 92%; kubelet eviction at 600Mi (soft) / 300Mi (hard), 60 s per pod |
| CPU starvation of k3s | 250m CPU and 768Mi reserved for k3s/OS; CPU limits on the heavy JVMs and Prometheus |
| Lake growth | bronze 15 days, weekly lakeFS GC (heartbeat + alarm), branch pruning |
| Prometheus / logs | retention 2 days / 1.5 GB; Airflow log groomer; journald ~80 MB |
| A job silently stopped | heartbeats with absence alarms: backup, lake copy, drill, silver freshness, GC, disk, cost guard |
| A failed Job, crash loop, full volume... | Prometheus alert rules counted by ops/node-health (no Alertmanager): OCI alarm when any warning/critical fires |
