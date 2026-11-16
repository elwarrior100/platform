#!/usr/bin/env bash
# Resume the platform after the cost kill-switch (ADR-017; envs/oracle/ops/cost-guard.yaml) stopped it. Run BY A
# PERSON from the Mac with their own OCI identity, AFTER finding (and fixing) what cost money (Cost Analysis by
# service). It:
#   1. shows the month's spend and the quota the guard created
#   2. deletes the quota cost-guard-zero (the VM itself may create quotas but never delete them)
#   3. tags the VM cost-guard-ack=<this month>:<spend now>: for the rest of the month the guard trips at that spend
#      + EUR 1.00 instead of stopping the VM again an hour later (the spend stays over EUR 1.00 until the month ends)
#   4. starts the VM
# Nothing else changes, and it asks before each step that changes the account. Dry run with --dry-run.
# Usage: ./scripts/cost-guard-resume.sh [--dry-run]
set -euo pipefail
DRY=false; [ "${1:-}" = --dry-run ] && DRY=true
TENANCY=$(awk -F= '/^tenancy/{gsub(/ /,"",$2); print $2; exit}' "${OCI_CONFIG_FILE:-$HOME/.oci/config}")
MONTH=$(date -u +%Y-%m)
ask() { [ "$DRY" = true ] && { echo "  (dry run: skipped)"; return 1; }; printf '%s [y/N] ' "$1"; read -r a; [ "$a" = y ]; }

SPEND=$(oci budgets budget budget list --compartment-id "$TENANCY" --all --query 'max_by(data, &"actual-spend")."actual-spend"' --raw-output)
echo "spend this month: EUR $SPEND (the guard trips at EUR 1.00)"

QUOTA=$(oci limits quota list --compartment-id "$TENANCY" --name cost-guard-zero --query 'data[0].id' --raw-output 2>/dev/null || true)
if [ -n "$QUOTA" ] && [ "$QUOTA" != null ]; then
  echo "quota cost-guard-zero is present (nothing paid can be created while it is)"
  if ask "delete the quota cost-guard-zero?"; then oci limits quota delete --quota-id "$QUOTA" --force >/dev/null; echo "  quota deleted"; fi
else
  echo "no quota cost-guard-zero"
fi

# shellcheck disable=SC2016  # the backticks are JMESPath literals, not shell
INSTANCE=$(oci compute instance list --compartment-id "$TENANCY" --display-name "${INSTANCE_NAME:-agente-01}" \
  --query 'data[?"lifecycle-state"!=`TERMINATED`] | [0].id' --raw-output)
[ -n "$INSTANCE" ] && [ "$INSTANCE" != null ] || { echo "VM ${INSTANCE_NAME:-agente-01} not found (set INSTANCE_NAME)" >&2; exit 1; }
STATE=$(oci compute instance get --instance-id "$INSTANCE" --query 'data."lifecycle-state"' --raw-output)
echo "VM state: $STATE"

# freeform tags are replaced as a whole: keep the others and set only cost-guard-ack
TAGS=$(oci compute instance get --instance-id "$INSTANCE" --query 'data."freeform-tags"' --output json \
  | python3 -c 'import json,sys; t=json.load(sys.stdin) or {}; t["cost-guard-ack"]=sys.argv[1]; print(json.dumps(t))' "$MONTH:$SPEND")
# only when the spend is really over the limit: otherwise (a test, a false trip) the tag would disarm the guard for
# the rest of the month for nothing
if python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= 1.0 else 1)' "$SPEND"; then
  if ask "tag the VM cost-guard-ack=$MONTH:$SPEND (until the month ends the guard trips only at EUR $SPEND + 1.00)?"; then
    oci compute instance update --instance-id "$INSTANCE" --freeform-tags "$TAGS" --force >/dev/null; echo "  tagged"
  fi
else
  echo "spend under EUR 1.00: no cost-guard-ack tag needed (the guard stays armed)"
fi

if [ "$STATE" = STOPPED ] && ask "start the VM?"; then
  oci compute instance action --instance-id "$INSTANCE" --action START >/dev/null
  echo "  START requested; in ~3 minutes: ssh ubuntu@platform-oracle 'sudo k3s kubectl get nodes'"
fi
