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

## lakeFS main is unreadable (a commit points at a missing object)
1. Stop the writer: `kubectl -n ingest scale deploy/writer --replicas=0`.
2. Remove the branch protection of `main` (lakeFS UI: repository settings, or the API `settings/branch_protection`),
   hard-reset `main` to the last readable commit, delete the broken `etl-*` branch, put the protection back
   (`scripts/lakefs-repo.sh` does it).
3. Set the spool batch back to `pending` and scale the writer to 1. Reconcile (project: `tests/phase3/run.sh`).

## Restore a database
- Backups: `platform-backups/<date>/` in Object Storage (nightly, 14 days). Prove they restore at any time:
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
