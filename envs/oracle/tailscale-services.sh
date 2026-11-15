#!/usr/bin/env bash
# HTTPS names for the web UIs: one Tailscale Service per UI on the Oracle VM (https://<name>.taila669aa.ts.net, valid
# certificate), each handing the request to Traefik on 127.0.0.1:80 with its Host header, so the Ingresses in
# envs/oracle/ingress route it like any other name. No pod in the cluster, no privileged container: Tailscale already
# runs on the VM (ADR-014). The sslip.io names stay as the fallback. Idempotent; run from the Mac, over Tailscale.
#
# Needs, once, in the Tailscale console (docs/runbook.md "HTTPS names"):
#   - policy: tagOwners "tag:platform": ["autogroup:admin"] and autoApprovers services "tag:platform": ["tag:platform"]
#   - the VM tagged tag:platform (a Service host must be a tagged device)
#   - the Services svc:<name> defined (port tcp:443, tag tag:platform)
# Usage: ./envs/oracle/tailscale-services.sh            (configure and check)
#        ./envs/oracle/tailscale-services.sh --check    (only check)
set -euo pipefail
HOST=platform-oracle
TAILNET=taila669aa.ts.net
SERVICES="airflow grafana argocd lakefs openmetadata"

if [ "${1:-}" != "--check" ]; then
  # shellcheck disable=SC2087   # the remote script is meant to expand SERVICES here, on the Mac
  ssh -o BatchMode=yes "ubuntu@$HOST" bash -s <<REMOTE
set -euo pipefail
tailscale status --json | python3 -c 'import json,sys; t=json.load(sys.stdin)["Self"].get("Tags") or []; sys.exit(0 if "tag:platform" in t else "the VM is not tagged tag:platform yet (Tailscale console: Machines > Edit ACL tags)")'
for s in $SERVICES; do
  sudo tailscale serve --bg --service="svc:\$s" --https=443 http://127.0.0.1:80 >/dev/null
done
sudo tailscale serve status
REMOTE
fi

echo "--- check from this machine"
rc=0
for s in $SERVICES; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://$s.$TAILNET/" || true)
  case "$code" in 2*|3*|401) echo "OK   https://$s.$TAILNET  (HTTP $code, certificate valid)" ;;
                  *) echo "FAIL https://$s.$TAILNET  (HTTP ${code:-none})"; rc=1 ;; esac
done
exit $rc
