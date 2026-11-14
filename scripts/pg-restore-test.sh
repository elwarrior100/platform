#!/usr/bin/env bash
# Proves the backups can be restored (Oracle only). Downloads the latest dump set from the platform-backups bucket,
# restores each database into a scratch database (restore_<db>) on the same Postgres, compares row counts table by
# table with the live database, then drops the scratch databases. Also checks that the VM CANNOT delete a backup.
# Usage: KUBECONFIG=~/.kube/oracle.yaml ./scripts/pg-restore-test.sh
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:?set KUBECONFIG to the Oracle cluster}"
DB_IMAGE="timescale/timescaledb:latest-pg17@sha256:6a6b7d7a346d7c6be03a310c240706f3bbc6d7adbdf3fbc07823570b34337f5e"
CLI_IMAGE="ghcr.io/oracle/oci-cli:latest@sha256:2127c2f50ee1353fa78cbf538ab91ffaccc0d02b6d0b4144530cef6ee69709f5"

kubectl -n data delete job pg-restore-test --ignore-not-found >/dev/null
kubectl apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata: {name: pg-restore-test, namespace: data}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels: {app: pg-restore-test, platform/metadata-access: "true"}
    spec:
      restartPolicy: Never
      volumes: [{name: dump, emptyDir: {}}]
      initContainers:
        - name: download
          image: $CLI_IMAGE
          env: [{name: OCI_CLI_AUTH, value: instance_principal}]
          command:
            - sh
            - -ec
            - |
              NS=\$(oci os ns get --query data --raw-output)
              LATEST=\$(oci os object list -ns \$NS -bn platform-backups --all --query 'data[].name' --raw-output | tr -d '[]", ' | grep / | sort | tail -1 | cut -d/ -f1)
              echo "latest backup: \$LATEST"
              oci os object bulk-download -ns \$NS -bn platform-backups --prefix "\$LATEST/" --download-dir /dump >/dev/null
              # the VM must NOT be able to delete a backup (policy allows create/read only)
              if oci os object delete -ns \$NS -bn platform-backups --name "\$LATEST/globals.sql" --force >/dev/null 2>&1; then
                echo "DELETE ALLOWED (policy too wide)"; exit 1
              else
                echo "delete refused, as intended"
              fi
              mv /dump/\$LATEST/* /dump/ && ls -l /dump
          volumeMounts: [{name: dump, mountPath: /dump}]
      containers:
        - name: restore
          image: $DB_IMAGE
          env:
            - name: PGPASSWORD
              valueFrom: {secretKeyRef: {name: postgres-auth, key: POSTGRES_PASSWORD}}
          command:
            - sh
            - -ec
            - |
              H=postgres.data.svc.cluster.local
              counts() { psql -h \$H -U postgres -d \$1 -At -F ' ' -c "select n.nspname||'.'||c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind='r' and n.nspname not in ('pg_catalog','information_schema') order by 1" | while read t; do echo "\$t \$(psql -h \$H -U postgres -d \$1 -At -c "select count(*) from \$t")"; done; }
              fail=0
              for f in /dump/*.dump; do
                db=\$(basename \$f .dump); scratch=restore_\$db
                psql -h \$H -U postgres -qc "drop database if exists \$scratch" -c "create database \$scratch"
                pg_restore -h \$H -U postgres -d \$scratch --no-owner --exit-on-error \$f
                counts \$db > /tmp/live; counts \$scratch > /tmp/rest
                tables=\$(wc -l < /tmp/rest); empty=0; ahead=0
                while read t n; do
                  live=\$(grep "^\$t " /tmp/live | cut -d' ' -f2)
                  [ "\$n" = 0 ] && [ "\${live:-0}" != 0 ] && empty=\$((empty+1))
                  [ "\$n" -gt "\${live:-0}" ] && ahead=\$((ahead+1))
                done < /tmp/rest
                rows=\$(awk '{s+=\$2} END {print s+0}' /tmp/rest); lrows=\$(awk '{s+=\$2} END {print s+0}' /tmp/live)
                echo "\$db: \$tables tables, \$rows rows restored (live now: \$lrows); empty-but-live: \$empty; restored>live: \$ahead"
                [ \$empty -gt 0 ] || [ \$ahead -gt 0 ] && fail=1
                psql -h \$H -U postgres -qc "drop database \$scratch"
              done
              [ \$fail = 0 ] && echo "RESTORE TEST OK" || { echo "RESTORE TEST FAILED"; exit 1; }
          volumeMounts: [{name: dump, mountPath: /dump}]
EOF
echo "restore test running (a few minutes)..."
kubectl -n data wait --for=condition=complete --timeout=900s job/pg-restore-test >/dev/null 2>&1 || true
P=$(kubectl -n data get pods -l job-name=pg-restore-test -o name | head -1)
kubectl -n data logs "$P" -c download | grep -E "latest backup|delete"
kubectl -n data logs "$P" -c restore
kubectl -n data get job pg-restore-test -o jsonpath='{.status.succeeded}' | grep -q 1
