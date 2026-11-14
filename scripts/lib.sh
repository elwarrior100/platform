# Shared helpers for the install scripts. Source it: . "$(dirname "$0")/lib.sh"
# Secrets are no longer created by scripts: the External Secrets Operator creates them from the OCI Vault
# (ADR-011). Scripts only wait for them and use their values, never printing them.

# wait_secret <namespace> <name>: waits up to 3 minutes for a Secret created by the External Secrets Operator.
wait_secret() {
  for _ in $(seq 1 36); do kubectl -n "$1" get secret "$2" >/dev/null 2>&1 && return 0; sleep 5; done
  echo "Secret $1/$2 not found. Is it in the vault (scripts/vault-seed.sh) and is the ExternalSecret synced?" >&2
  echo "  kubectl -n $1 describe externalsecret $2" >&2
  return 1
}

# secret_value <namespace> <name> <key>: prints one value to stdout (only ever piped, never shown).
secret_value() { kubectl -n "$1" get secret "$2" -o jsonpath="{.data.$3}" | base64 -d; }

# url_password: reads a connection URL on stdin and prints its password (stdin to stdout, never in argv).
url_password() { python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(urllib.parse.urlsplit(sys.stdin.read().strip()).password))'; }

# ensure_pg_role <role> <database>: reads the password on stdin and makes sure the role (with that password)
# and its database exist in the platform PostgreSQL. Idempotent: on a new cluster it creates them, on an
# existing one it only re-applies the same password.
ensure_pg_role() {
  local role="$1" db="$2"
  {
    cat                              # first line: the password, read by the shell inside the pod
    cat <<SQL
SELECT format('CREATE ROLE $role LOGIN PASSWORD %L', :'pw') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$role') \gexec
SELECT format('ALTER ROLE $role PASSWORD %L', :'pw') \gexec
SELECT 'CREATE DATABASE $db OWNER $role' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$db') \gexec
SQL
  } | kubectl -n data exec -i postgres-0 -- sh -c 'read PW; psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres -v pw="$PW" -f -'
}
