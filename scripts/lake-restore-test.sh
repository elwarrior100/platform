#!/usr/bin/env bash
# Lake restore drill (Oracle only): proves that the backups ALONE rebuild the lake, without touching anything live.
# One throw-away pod in a temporary namespace (lake-drill) runs, all on localhost:
#   fetch           newest complete dump set (_COMPLETE) from platform-backups: globals.sql + lakefs.dump
#   postgres        a scratch Postgres (sidecar)              <- globals + lakefs.dump restored into it
#   seaweedfs       a scratch SeaweedFS (sidecar, bucket lake) <- every object of platform-lake-backup copied into it
#   lakefs          a scratch lakeFS on those two (sidecar), with the same encryption key and admin key as the real one
#   check           for every repository: main's commit, its object count, and a download of EVERY object on main
# The drill passes only if every object listed on main downloads. The live Postgres, SeaweedFS and lakeFS are never
# contacted; the namespace (with its copy of the lakeFS key) is deleted at the end, pass or fail.
# Usage: KUBECONFIG=~/.kube/oracle.yaml ./scripts/lake-restore-test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:?set KUBECONFIG to the Oracle cluster}"
NS=lake-drill
CLI_IMAGE="ghcr.io/oracle/oci-cli:latest@sha256:2127c2f50ee1353fa78cbf538ab91ffaccc0d02b6d0b4144530cef6ee69709f5"
DB_IMAGE="timescale/timescaledb:latest-pg17@sha256:6a6b7d7a346d7c6be03a310c240706f3bbc6d7adbdf3fbc07823570b34337f5e"
SW_IMAGE="chrislusf/seaweedfs:latest@sha256:ccad23e18639c8b98cee17e7100b95830a06077b56d8e5b006d6dcf8ec5e94a0"
RCLONE_IMAGE="rclone/rclone:1.71.2@sha256:3103526c506266a9ecdf064efe99bf3677d92ef6407af124d8c56b4f49cbaa51"
LAKEFS_IMAGE="treeverse/lakefs:1.86.0@sha256:fb7a0d90f77e3f893e8b8c6f3be131c090f6f0160c2d6c7784c4378cf7e66ea1"

# shellcheck disable=SC2329  # called by the EXIT trap
cleanup() { kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

# the same OCI service ranges the backup namespace may reach (kept in one place: the backup egress policy)
OSN=$(sed -n '/oci-osn-cidrs:begin/,/oci-osn-cidrs:end/p' "$ROOT/envs/oracle/backup/networkpolicy.yaml" | grep 'ipBlock')

kubectl delete namespace "$NS" --ignore-not-found --wait=true >/dev/null
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/warn: baseline
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: drill, namespace: $NS}
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]    # nothing may connect in; out only DNS, the metadata endpoint and OCI services
  ingress: []
  egress:
    - to:
        - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}
          podSelector: {matchLabels: {k8s-app: kube-dns}}
      ports: [{port: 53, protocol: UDP}, {port: 53, protocol: TCP}]
    - to: [{ipBlock: {cidr: 169.254.169.254/32}}]
      ports: [{port: 80, protocol: TCP}]
    - to:
$OSN
      ports: [{port: 443, protocol: TCP}]
EOF

# the lakeFS keys, copied through a pipe (never printed): the restored database holds the admin credentials encrypted
# with AUTH_ENCRYPT_SECRET_KEY, so the scratch lakeFS needs the same key to read them
kubectl -n data get secret lakefs-auth -o json | python3 -c '
import json, sys
s = json.load(sys.stdin)
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                  "metadata": {"name": "lakefs-auth", "namespace": sys.argv[1]}, "data": s["data"]}))' "$NS" \
  | kubectl apply -f - >/dev/null

kubectl apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata: {name: lake-restore-test, namespace: $NS}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 900     # even if this script dies (Mac asleep), the pod stops after 15 minutes
  template:
    metadata:
      labels: {app: lake-restore-test}
    spec:
      restartPolicy: Never
      volumes: [{name: dump, emptyDir: {}}, {name: pg, emptyDir: {}}, {name: sw, emptyDir: {}}]
      initContainers:
        - name: fetch
          image: $CLI_IMAGE
          env: [{name: OCI_CLI_AUTH, value: instance_principal}]
          command: [sh, -ec]
          args:
            - |
              sleep 10   # kube-router adds a new pod to the egress allow-lists with a few seconds of delay
              NS=\$(oci os ns get --query data --raw-output)
              LATEST=\$(oci os object list -ns \$NS -bn platform-backups --all --query 'data[].name' --raw-output | tr -d '[]", ' | grep '/_COMPLETE\$' | sort | tail -1 | xargs dirname)
              echo "dump set: \$LATEST"
              for f in globals.sql lakefs.dump; do oci os object get -ns \$NS -bn platform-backups --name "\$LATEST/\$f" --file /dump/\$f; done
              echo "\$LATEST" > /dump/SET
              REGION=\$(python3 -c 'import json,urllib.request; print(json.load(urllib.request.urlopen(urllib.request.Request("http://169.254.169.254/opc/v2/instance/", headers={"Authorization": "Bearer Oracle"})))["canonicalRegionName"])')
              printf 'export RCLONE_CONFIG_OCI_NAMESPACE=%s RCLONE_CONFIG_OCI_REGION=%s\n' "\$NS" "\$REGION" > /dump/oci.env
          volumeMounts: [{name: dump, mountPath: /dump}]
        - name: postgres                     # sidecar: runs until the pod ends
          image: $DB_IMAGE
          restartPolicy: Always
          env: [{name: POSTGRES_HOST_AUTH_METHOD, value: trust}, {name: PGDATA, value: /pg/data}]
          startupProbe: {exec: {command: [pg_isready, -h, 127.0.0.1, -U, postgres]}, periodSeconds: 2, failureThreshold: 60}
          volumeMounts: [{name: pg, mountPath: /pg}]
          resources: {requests: {cpu: 50m, memory: 128Mi}, limits: {memory: 512Mi}}
        - name: seaweedfs                    # sidecar; no s3 config = no authentication (the namespace policy lets nothing in)
          image: $SW_IMAGE
          restartPolicy: Always
          args: [server, -dir=/data, -ip=127.0.0.1, -ip.bind=0.0.0.0, -master.volumeSizeLimitMB=64, -volume.max=20, -s3, -s3.port=8333]
          startupProbe: {tcpSocket: {port: 8333}, periodSeconds: 2, failureThreshold: 60}
          volumeMounts: [{name: sw, mountPath: /data}]
          resources: {requests: {cpu: 50m, memory: 128Mi}, limits: {memory: 512Mi}}
        - name: restore-db
          image: $DB_IMAGE
          command: [sh, -ec]
          args:
            - |
              psql -q -h 127.0.0.1 -U postgres -f /dump/globals.sql >/dev/null 2>&1 || true   # roles (postgres exists: harmless error)
              createdb -h 127.0.0.1 -U postgres -O lakefs lakefs
              pg_restore -h 127.0.0.1 -U postgres -d lakefs --exit-on-error /dump/lakefs.dump
              echo "lakefs database restored: \$(psql -h 127.0.0.1 -U postgres -d lakefs -tAc "select count(*) from kv") kv rows"
          volumeMounts: [{name: dump, mountPath: /dump}]
        - name: restore-objects
          image: $RCLONE_IMAGE
          env:
            - {name: RCLONE_CONFIG_OCI_TYPE, value: oracleobjectstorage}
            - {name: RCLONE_CONFIG_OCI_PROVIDER, value: instance_principal_auth}
            - {name: RCLONE_CONFIG_LAKE_TYPE, value: s3}
            - {name: RCLONE_CONFIG_LAKE_PROVIDER, value: SeaweedFS}
            - {name: RCLONE_CONFIG_LAKE_ENDPOINT, value: "http://127.0.0.1:8333"}
          command: [sh, -ec]
          args:
            - |
              . /dump/oci.env
              rclone mkdir lake:lake
              rclone copy oci:platform-lake-backup lake:lake --transfers 4 --checkers 8 --stats-one-line -q
              echo "objects restored into the scratch SeaweedFS: \$(rclone size lake:lake --json)"
          volumeMounts: [{name: dump, mountPath: /dump}]
          resources: {requests: {cpu: 50m, memory: 64Mi}, limits: {memory: 256Mi}}
        - name: lakefs                       # sidecar, started only after both restores
          image: $LAKEFS_IMAGE
          restartPolicy: Always
          args: [run]
          env:
            - {name: LAKEFS_DATABASE_TYPE, value: postgres}
            - {name: LAKEFS_DATABASE_POSTGRES_CONNECTION_STRING, value: "postgres://lakefs@127.0.0.1:5432/lakefs?sslmode=disable"}
            - {name: LAKEFS_AUTH_ENCRYPT_SECRET_KEY, valueFrom: {secretKeyRef: {name: lakefs-auth, key: AUTH_ENCRYPT_SECRET_KEY}}}
            - {name: LAKEFS_BLOCKSTORE_TYPE, value: s3}
            - {name: LAKEFS_BLOCKSTORE_S3_ENDPOINT, value: "http://127.0.0.1:8333"}
            - {name: LAKEFS_BLOCKSTORE_S3_FORCE_PATH_STYLE, value: "true"}
            - {name: LAKEFS_BLOCKSTORE_S3_DISCOVER_BUCKET_REGION, value: "false"}
            - {name: LAKEFS_BLOCKSTORE_S3_REGION, value: us-east-1}
            - {name: LAKEFS_BLOCKSTORE_S3_CREDENTIALS_ACCESS_KEY_ID, value: drill}
            - {name: LAKEFS_BLOCKSTORE_S3_CREDENTIALS_SECRET_ACCESS_KEY, value: drill}
            - {name: LAKEFS_BLOCKSTORE_S3_DISABLE_PRE_SIGNED, value: "true"}
            - {name: LAKEFS_EMAIL_SUBSCRIPTION_ENABLED, value: "false"}
            - {name: LAKEFS_STATS_ENABLED, value: "false"}
          startupProbe: {httpGet: {path: /_health, port: 8000}, periodSeconds: 2, failureThreshold: 90}
          resources: {requests: {cpu: 50m, memory: 128Mi}, limits: {memory: 1Gi}}
      containers:
        - name: check
          image: $LAKEFS_IMAGE
          env:
            - {name: LAKECTL_SERVER_ENDPOINT_URL, value: "http://127.0.0.1:8000"}
            - {name: LAKECTL_CREDENTIALS_ACCESS_KEY_ID, valueFrom: {secretKeyRef: {name: lakefs-auth, key: ADMIN_ACCESS_KEY_ID}}}
            - {name: LAKECTL_CREDENTIALS_SECRET_ACCESS_KEY, valueFrom: {secretKeyRef: {name: lakefs-auth, key: ADMIN_SECRET_ACCESS_KEY}}}
          command: [sh, -ec]
          args:
            - |
              echo "dump set: \$(cat /dump/SET)"
              REPOS=\$(lakectl repo list --amount 1000 | awk -F'\\t' 'NF>1 {print \$1}')   # tab-separated when not a terminal
              [ -n "\$REPOS" ] || { echo "FAIL: no repository in the restored lakeFS" >&2; exit 1; }
              fail=0
              for r in \$REPOS; do
                COMMIT=\$(lakectl log --amount 1 --no-color lakefs://\$r/main | awk '/^ID:/ {print \$2; exit}')
                WHEN=\$(lakectl log --amount 1 --no-color lakefs://\$r/main | awk '/^Date:/ {sub(/^Date: */, ""); print; exit}')
                LISTED=\$(lakectl fs ls -r lakefs://\$r/main/ | grep -c '^object' || true)
                mkdir -p /tmp/out/\$r
                lakectl fs download -r --pre-sign=false --parallelism 4 lakefs://\$r/main/ /tmp/out/\$r/ >/dev/null 2>/tmp/err || true
                GOT=\$(find /tmp/out/\$r -type f | wc -l | tr -d ' ')
                if [ "\$LISTED" -gt 0 ] && [ "\$GOT" -eq "\$LISTED" ]; then status=OK; else status=FAIL; fail=1; tail -3 /tmp/err; fi
                echo "\$r: main \$COMMIT (\$WHEN), \$LISTED objects listed, \$GOT downloaded: \$status"
              done
              [ \$fail -eq 0 ] && echo "LAKE RESTORE TEST OK" || { echo "LAKE RESTORE TEST FAILED"; exit 1; }
          volumeMounts: [{name: dump, mountPath: /dump}]
          resources: {requests: {cpu: 50m, memory: 64Mi}, limits: {memory: 256Mi}}
EOF

echo "drill running (fetch, restore the database and the objects, start a scratch lakeFS, read everything on main)..."
rc=1   # wait until the Job either completes or fails (at most 15 minutes)
for _ in $(seq 1 180); do
  st=$(kubectl -n "$NS" get job lake-restore-test -o jsonpath='{.status.succeeded}/{.status.failed}')
  case "$st" in 1/*) rc=0; break ;; */1) break ;; esac
  sleep 5
done
POD=$(kubectl -n "$NS" get pod -l job-name=lake-restore-test -o name | head -1)
for c in fetch restore-db restore-objects check; do kubectl -n "$NS" logs "$POD" -c "$c" 2>/dev/null | grep -v NOTICE; done
[ $rc -eq 0 ] || { echo "--- the drill did not complete; container states:"; kubectl -n "$NS" get "$POD" -o jsonpath='{range .status.initContainerStatuses[*]}{.name}={.state}{"\n"}{end}{range .status.containerStatuses[*]}{.name}={.state}{"\n"}{end}'; kubectl -n "$NS" logs "$POD" -c lakefs --tail=5 2>/dev/null; }
exit $rc
