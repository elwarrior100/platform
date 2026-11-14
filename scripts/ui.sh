#!/usr/bin/env bash
# Opens tunnels to the cluster web UIs and tells you where to click.
#   ./scripts/ui.sh           opens the tunnels and keeps running (Ctrl-C closes everything)
#   ./scripts/ui.sh --open    same, and opens the pages in the browser
#   ./scripts/ui.sh --check   opens, tests each one, prints the result and exits
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"
MODE="${1:-}"

# name | namespace | service | local port | service port | path to test (- = TCP only)
UIS=(
  "Argo CD|argocd|svc/argocd-server|8081|80|/"
  "lakeFS|data|svc/lakefs|8082|8000|/"
  "SeaweedFS (files)|data|svc/seaweedfs|8888|8888|/"
  "Simulator (control)|ot|svc/ot-edge|8083|8080|/health"
  "Airflow|airflow|svc/airflow-api-server|8084|8080|/"
  "OPC UA (use UaExpert)|ot|svc/ot-edge|4840|4840|-"
)

if ! kubectl get nodes >/dev/null 2>&1; then
  echo "Cannot reach the cluster. Is the VM running?  ./scripts/vm-start.sh" >&2
  exit 1
fi

PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT INT TERM

for ui in "${UIS[@]}"; do
  IFS='|' read -r name ns svc local remote path <<<"$ui"
  if nc -z 127.0.0.1 "$local" 2>/dev/null; then
    echo "WARNING: port $local is already in use; skipping '$name'" >&2
    continue
  fi
  kubectl -n "$ns" port-forward "$svc" "$local:$remote" >/dev/null 2>&1 &
  PIDS+=("$!")
done

for ui in "${UIS[@]}"; do
  IFS='|' read -r name ns svc local remote path <<<"$ui"
  for _ in $(seq 1 15); do nc -z 127.0.0.1 "$local" 2>/dev/null && break; sleep 1; done
done

printf '\n%-26s %-30s %s\n' "WHAT" "WHERE TO OPEN" "STATUS"
printf '%-26s %-30s %s\n' "-------" "----------" "------"
failed=0
for ui in "${UIS[@]}"; do
  IFS='|' read -r name ns svc local remote path <<<"$ui"
  if [ "$path" = "-" ]; then
    url="opc.tcp://localhost:$local/ot-gateway"
    nc -z 127.0.0.1 "$local" 2>/dev/null && state="listening" || { state="NO CONNECTION"; failed=1; }
  else
    url="http://localhost:$local"
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url$path")
    case "$code" in 2*|3*|401) state="OK (HTTP $code)";; *) state="FAILED (HTTP $code)"; failed=1;; esac
  fi
  printf '%-26s %-30s %s\n' "$name" "$url" "$state"
  [ "$MODE" = "--open" ] && [ "$path" != "-" ] && open "$url"
done

if [ "$MODE" = "--check" ]; then exit "$failed"; fi

cat <<'TXT'

PASSWORDS (copied to the clipboard; paste with Cmd+V):
  Argo CD   (user: admin)
    KUBECONFIG=$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d | pbcopy
  Airflow   (user: admin)
    KUBECONFIG=$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml kubectl -n airflow get secret airflow-admin -o jsonpath='{.data.password}' | base64 -d | pbcopy
  lakeFS    (user = access key; password = secret key)
    KUBECONFIG=$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml kubectl -n data get secret lakefs-auth -o jsonpath='{.data.ADMIN_ACCESS_KEY_ID}' | base64 -d | pbcopy
    KUBECONFIG=$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml kubectl -n data get secret lakefs-auth -o jsonpath='{.data.ADMIN_SECRET_ACCESS_KEY}' | base64 -d | pbcopy

Ctrl-C closes the tunnels.
TXT
wait
