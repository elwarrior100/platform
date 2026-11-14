#!/usr/bin/env bash
# Writes a note on your Mac with the users and passwords of the web UIs.
# The note stays OUTSIDE the repository (by default in ~/Documents) and only you can read it (chmod 600).
# Usage: ./scripts/save-credentials.sh [note-path]
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"
NOTE="${1:-$HOME/Documents/platform-access.md}"

case "$(cd "$(dirname "$NOTE")" && pwd)/" in
  "$(cd "$(dirname "$0")/.." && pwd)"/*) echo "Refused: the note cannot live inside the repository (it would end up in git)." >&2; exit 1;;
esac

secret() { kubectl -n "$1" get secret "$2" -o jsonpath="{.data.$3}" | base64 -d; }

umask 077
{
  echo "# Platform access (generated on $(date '+%Y-%m-%d %H:%M'))"
  echo
  echo "Open the tunnels: \`./scripts/ui.sh --open\`. Passwords change if the cluster is recreated: run \`save-credentials.sh\` again."
  echo
  echo "| Service | Address | User | Password |"
  echo "|---|---|---|---|"
  echo "| Argo CD | http://localhost:8081 | admin | $(secret argocd argocd-initial-admin-secret password) |"
  echo "| Airflow | http://localhost:8084 | admin | $(secret airflow airflow-admin password) |"
  echo "| lakeFS | http://localhost:8082 | $(secret data lakefs-auth ADMIN_ACCESS_KEY_ID) | $(secret data lakefs-auth ADMIN_SECRET_ACCESS_KEY) |"
  echo "| SeaweedFS | http://localhost:8888 | (no login) | |"
  echo "| Simulator | http://localhost:8083 | (no login) | |"
  echo "| OPC UA | opc.tcp://localhost:4840/ot-gateway | (anonymous) | |"
} > "$NOTE"
chmod 600 "$NOTE"
echo "Note written to $NOTE (readable only by you). Nothing in it goes to git."
