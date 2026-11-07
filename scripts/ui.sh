#!/usr/bin/env bash
# Abre túneis para as interfaces do cluster e diz onde clicar.
#   ./platform/scripts/ui.sh           abre os túneis e fica a correr (Ctrl-C fecha tudo)
#   ./platform/scripts/ui.sh --open    idem, e abre as páginas no browser
#   ./platform/scripts/ui.sh --check   abre, testa cada uma, imprime o resultado e sai
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"
MODE="${1:-}"

# nome | namespace | serviço | porto local | porto do serviço | caminho a testar (- = só TCP)
UIS=(
  "Argo CD|argocd|svc/argocd-server|8081|80|/"
  "lakeFS|data|svc/lakefs|8082|8000|/"
  "SeaweedFS (ficheiros)|data|svc/seaweedfs|8888|8888|/"
  "Simulador (controlo)|ot|svc/ot-edge|8083|8080|/health"
  "Airflow|airflow|svc/airflow-api-server|8084|8080|/"
  "OPC UA (usar o UaExpert)|ot|svc/ot-edge|4840|4840|-"
)

if ! kubectl get nodes >/dev/null 2>&1; then
  echo "Não consigo falar com o cluster. A VM está ligada?  limactl start industrial" >&2
  exit 1
fi

PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT INT TERM

for ui in "${UIS[@]}"; do
  IFS='|' read -r name ns svc local remote path <<<"$ui"
  if nc -z 127.0.0.1 "$local" 2>/dev/null; then
    echo "AVISO: o porto $local já está ocupado; salto '$name'" >&2
    continue
  fi
  kubectl -n "$ns" port-forward "$svc" "$local:$remote" >/dev/null 2>&1 &
  PIDS+=("$!")
done

for ui in "${UIS[@]}"; do
  IFS='|' read -r name ns svc local remote path <<<"$ui"
  for _ in $(seq 1 15); do nc -z 127.0.0.1 "$local" 2>/dev/null && break; sleep 1; done
done

printf '\n%-26s %-30s %s\n' "O QUE É" "ONDE ABRIR" "ESTADO"
printf '%-26s %-30s %s\n' "-------" "----------" "------"
failed=0
for ui in "${UIS[@]}"; do
  IFS='|' read -r name ns svc local remote path <<<"$ui"
  if [ "$path" = "-" ]; then
    url="opc.tcp://localhost:$local/ot-gateway"
    nc -z 127.0.0.1 "$local" 2>/dev/null && state="a escutar" || { state="SEM LIGAÇÃO"; failed=1; }
  else
    url="http://localhost:$local"
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url$path")
    case "$code" in 2*|3*|401) state="OK (HTTP $code)";; *) state="FALHOU (HTTP $code)"; failed=1;; esac
  fi
  printf '%-26s %-30s %s\n' "$name" "$url" "$state"
  [ "$MODE" = "--open" ] && [ "$path" != "-" ] && open "$url"
done

if [ "$MODE" = "--check" ]; then exit "$failed"; fi

cat <<'TXT'

PALAVRAS-PASSE (vão para a área de transferência; cola com Cmd+V):
  Argo CD   (utilizador: admin)
    KUBECONFIG=$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d | pbcopy
  Airflow   (utilizador: admin)
    KUBECONFIG=$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml kubectl -n airflow get secret airflow-admin -o jsonpath='{.data.password}' | base64 -d | pbcopy
  lakeFS    (utilizador = chave de acesso; palavra-passe = chave secreta)
    KUBECONFIG=$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml kubectl -n data get secret lakefs-auth -o jsonpath='{.data.ADMIN_ACCESS_KEY_ID}' | base64 -d | pbcopy
    KUBECONFIG=$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml kubectl -n data get secret lakefs-auth -o jsonpath='{.data.ADMIN_SECRET_ACCESS_KEY}' | base64 -d | pbcopy

Ctrl-C para fechar os túneis.
TXT
wait
