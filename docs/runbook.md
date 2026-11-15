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
1. Stop the writer: `kubectl -n ingest scale deploy/writer --replicas=0`.
2. Remove the branch protection of `main` (lakeFS UI: repository settings, or the API `settings/branch_protection`),
   hard-reset `main` to the last readable commit, delete the broken `etl-*` branch, put the protection back
   (`scripts/lakefs-repo.sh` does it).
3. Set the spool batch back to `pending` and scale the writer to 1. Reconcile (project: `tests/phase3/run.sh`).

## An alarm email arrived (OCI Notifications, topic platform-alerts)
| Alarm | First look |
|---|---|
| VM not reporting | `ssh ubuntu@platform-oracle`; if no answer, OCI console: instance state, serial console |
| CPU > 90% / memory > 92% | Grafana (`http://grafana.100.108.9.15.sslip.io`, or `./scripts/ui.sh` :3000), "Kubernetes / Compute Resources / Namespace"; `kubectl top pods -A` |
| no successful backup in 26 h | `kubectl -n backup get jobs`; logs of the newest `pg-backup` job |
| no successful lake copy in 26 h | `kubectl -n backup get jobs`; logs of the newest `lake-sync` job (it refuses to overwrite: an "immutable" error means an object changed, which lakeFS objects never should) |
| silver not updated for 3 h | Airflow `silver_hourly` runs (a G2 fail is expected for incomplete hours); writer logs; `kubectl -n ops logs` of the last freshness job |
| bucket above N GB | `oci os object list` on the bucket; dumps expire after 14 days, the lake copy only grows |

## A new job pod cannot connect for its first seconds
kube-router adds a new pod to the network-policy allow-lists a few seconds after it starts. Jobs must retry their
first connection (pg-backup waits for `pg_isready`). Symptom: "Connection refused" that disappears on a retry.

## Restore the lake (lakeFS metadata + objects)
It is drilled every day at 04:15 UTC (`ops/lake-restore-drill`: rebuilds lakeFS from the newest dump and the object
copy inside one throw-away pod, compares the MD5 of every object on `main`; alarm after 2 days without a pass).
Run it now, without touching anything live: `KUBECONFIG=~/.kube/oracle.yaml ./scripts/lake-restore-test.sh`. The real restore:
1. Stop writers: scale `ingest/writer` and pause the Airflow DAGs.
2. Objects: `rclone copy oci:platform-lake-backup lake:lake` (same configuration as the lake-sync job, reversed),
   from a pod in the `backup` namespace labelled `app: lake-sync` (SeaweedFS only accepts the lake copy and lakeFS).
   The backup key is read-only (`backup-seaweedfs-reader`): for the reverse copy use the admin key of
   `data-seaweedfs-auth`, in a temporary Secret deleted afterwards.
3. Metadata: restore the `lakefs` database from the newest complete dump (see below), then restart lakeFS.
4. Check: list `main` in lakeFS and read a bronze and a silver file; reconcile the spool (project: tests/phase3/run.sh).

## Restore a database
- Backups: `platform-backups/<date>/<HHMMSS>/` in Object Storage (one prefix per run, nightly, kept 14 days); a run
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

## Monthly: prune the lake copy (a person, from the Mac)
The VM can never delete from `platform-lake-backup` (that is what makes the copy tamper-proof), so once lakeFS GC
removes objects from the lake, their copies stay until a person prunes them:
```
KUBECONFIG=~/.kube/oracle.yaml ./scripts/lake-backup-prune.sh            # dry run: what would go
KUBECONFIG=~/.kube/oracle.yaml ./scripts/lake-backup-prune.sh --apply    # asks you to type the count
```
Only objects missing from the lake for 30 days (counted from the first run that saw them missing, kept in
`_prune/missing.json`) go, so an object lost to corruption keeps its copy. Forgetting it is not dangerous,
only costly: the `storage_high` alarm (12 GB on the copy) is the reminder.

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
GC retention (15 days, `scripts/lakefs-repo.sh`) must stay >= the dump lifecycle (14 days): CI checks it.

## CPU and memory headroom (2 OCPU, 12 GB)
The kubelet reserves 250m CPU and 768Mi for k3s and the OS (`kubelet.conf.d/98-reserved.conf`, bootstrap-vm.sh):
pods see 1.75 CPU. Requests follow measured use (`kubectl top pods -A`); heavy JVMs (OpenMetadata, OpenSearch) and
Prometheus have CPU limits. Re-runnable batch jobs (GC, drill) use PriorityClass `platform-batch`. Memory eviction by the kubelet (k3s
`config.yaml`: soft 600Mi for 1 min, hard 300Mi) evicts pods over their requests first, then by priority; the kernel
OOM killer (QoS-based, priority-blind) only acts if memory runs out faster than that.
