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

## The Airflow scheduler crash-loops after a reboot (known Airflow 3.2.2 bug)
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

## Restore a database
- Backups: `platform-backups/<date>/<HHMMSS>/` in Object Storage (one prefix per run, nightly, kept 14 days). Prove they restore at any time:
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
