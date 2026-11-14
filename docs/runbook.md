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
| CPU > 90% / memory > 92% | Grafana (`./scripts/ui.sh`, :3000), "Kubernetes / Compute Resources / Namespace"; `kubectl top pods -A` |
| no successful backup in 26 h | `kubectl -n backup get jobs`; logs of the newest `pg-backup` job |
| no successful lake copy in 26 h | `kubectl -n backup get jobs`; logs of the newest `lake-sync` job (it refuses to overwrite: an "immutable" error means an object changed, which lakeFS objects never should) |
| silver not updated for 3 h | Airflow `silver_hourly` runs (a G2 fail is expected for incomplete hours); writer logs; `kubectl -n ops logs` of the last freshness job |
| bucket above N GB | `oci os object list` on the bucket; dumps expire after 14 days, the lake copy only grows |

## A new job pod cannot connect for its first seconds
kube-router adds a new pod to the network-policy allow-lists a few seconds after it starts. Jobs must retry their
first connection (pg-backup waits for `pg_isready`). Symptom: "Connection refused" that disappears on a retry.

## Restore the lake (lakeFS metadata + objects)
Drill first, at any time and without touching anything live: `KUBECONFIG=~/.kube/oracle.yaml ./scripts/lake-restore-test.sh`
(rebuilds lakeFS from the newest dump and the object copy in a throw-away namespace, then reads every object on
`main`). The real restore:
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
