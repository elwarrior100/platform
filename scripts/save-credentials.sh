#!/usr/bin/env bash
# Cria uma nota no teu Mac com os utilizadores e palavras-passe das interfaces.
# A nota fica FORA do repositório (por omissão em ~/Documents) e só tu a podes ler (chmod 600).
# Uso: ./platform/scripts/save-credentials.sh [caminho-da-nota]
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.lima/industrial/copied-from-guest/kubeconfig.yaml}"
NOTE="${1:-$HOME/Documents/modbus-plataforma-acessos.md}"

case "$(cd "$(dirname "$NOTE")" && pwd)/" in
  "$(cd "$(dirname "$0")/../.." && pwd)"/*) echo "Recusado: a nota não pode ficar dentro do repositório (iria para o git)." >&2; exit 1;;
esac

secret() { kubectl -n "$1" get secret "$2" -o jsonpath="{.data.$3}" | base64 -d; }

umask 077
{
  echo "# Acessos da plataforma (gerado em $(date '+%Y-%m-%d %H:%M'))"
  echo
  echo "Abrir os túneis: \`./platform/scripts/ui.sh --open\`. As palavras-passe mudam se o cluster for recriado: volta a correr \`save-credentials.sh\`."
  echo
  echo "| Serviço | Endereço | Utilizador | Palavra-passe |"
  echo "|---|---|---|---|"
  echo "| Argo CD | http://localhost:8081 | admin | $(secret argocd argocd-initial-admin-secret password) |"
  echo "| Airflow | http://localhost:8084 | admin | $(secret airflow airflow-admin password) |"
  echo "| lakeFS | http://localhost:8082 | $(secret data lakefs-auth ADMIN_ACCESS_KEY_ID) | $(secret data lakefs-auth ADMIN_SECRET_ACCESS_KEY) |"
  echo "| SeaweedFS | http://localhost:8888 | (sem login) | |"
  echo "| Simulador | http://localhost:8083 | (sem login) | |"
  echo "| OPC UA | opc.tcp://localhost:4840/ot-gateway | (anónimo) | |"
} > "$NOTE"
chmod 600 "$NOTE"
echo "Nota criada em $NOTE (só tu a podes ler). Não contém nada que vá para o git."
